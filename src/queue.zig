//! Concurrent, bounded, array-backed queues. Follows the design of Vyukov's
//! bounded MPMC queue: https://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue

const std = @import("std");
const builtin = @import("builtin");

pub const Variant = enum {
    SPSC,
    MPSC,
    SPMC,
    MPMC,

    const Producer = enum { SP, MP };
    const Consumer = enum { SC, MC };

    pub fn fromDescription(p: Producer, c: Consumer) Variant {
        if (p == .SP and c == .SC) return .SPSC;
        if (p == .MP and c == .SC) return .MPSC;
        if (p == .SP and c == .MC) return .SPMC;
        return .MPMC;
    }

    fn multiProducer(v: Variant) bool {
        return switch (v) {
            .SPSC, .SPMC => false,
            .MPSC, .MPMC => true,
        };
    }

    fn multiConsumer(v: Variant) bool {
        return switch (v) {
            .SPSC, .MPSC => false,
            .SPMC, .MPMC => true,
        };
    }
};

const cache_line_bytes = switch (builtin.cpu.arch) {
    .x86_64 => 64,
    .aarch64 => if (builtin.os.tag.isDarwin()) 128 else 64,
    else => @compileError("Unsupported/untested CPU architecture"),
};

/// A convenience wrapper for synchronized memory locations. This is a subset
/// of the current std.atomic.Atomic functionality, but is implemented as a
/// bare (non-extern) struct so we can use very narrow (sub-byte) types for
/// testing. We can likely drop this in favor of std.atomic.Atomic once 
/// https://github.com/ziglang/zig/issues/5049 is resolved.
fn Atomic(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();
        const Ordering = std.atomic.Ordering;

        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        pub inline fn load(self: *const Self, comptime ordering: Ordering) T {
            return switch (ordering) {
                .AcqRel => @compileError(@tagName(ordering) ++ " implies " ++ @tagName(Ordering.Release) ++ " which is only allowed on atomic stores"),
                .Release => @compileError(@tagName(ordering) ++ " is only allowed on atomic stores"),
                else => @atomicLoad(T, &self.value, ordering),
            };
        }

        pub inline fn store(self: *Self, value: T, comptime ordering: Ordering) void {
            return switch (ordering) {
                .AcqRel => @compileError(@tagName(ordering) ++ " implies " ++ @tagName(Ordering.Acquire) ++ " which is only allowed on atomic loads"),
                .Acquire => @compileError(@tagName(ordering) ++ " is only allowed on atomic loads"),
                else => @atomicStore(T, &self.value, value, ordering),
            };
        }

        pub inline fn tryCompareAndSwap(
            self: *Self,
            compare: T,
            exchange: T,
            comptime success: Ordering,
            comptime failure: Ordering,
        ) ?T {
            if (success == .Unordered or failure == .Unordered) {
                @compileError(@tagName(Ordering.Unordered) ++ " is only allowed on atomic loads and stores");
            }

            comptime var success_is_stronger = switch (failure) {
                .SeqCst => success == .SeqCst,
                .AcqRel => @compileError(@tagName(failure) ++ " implies " ++ @tagName(Ordering.Release) ++ " which is only allowed on success"),
                .Acquire => success == .SeqCst or success == .AcqRel or success == .Acquire,
                .Release => @compileError(@tagName(failure) ++ " is only allowed on success"),
                .Monotonic => true,
                .Unordered => unreachable,
            };

            if (!success_is_stronger) {
                @compileError(@tagName(success) ++ " must be stronger than " ++ @tagName(failure));
            }

            return @cmpxchgWeak(T, &self.value, compare, exchange, success, failure);
        }

        pub inline fn fetchSub(self: *Self, value: T, comptime ordering: Ordering) T {
            return @atomicRmw(T, &self.value, .Sub, value, ordering);
        }
    };
}

// NOTE: Internally, for serial unit testing, we support a narrow Index type to
// facilitate testing overflow conditions. But there's a very subtle issue in
// the design of this queue, where a thread can be descheduled after performing
// the two "load" operations in an enqueue (or dequeue), the queue position
// wraps around, and then the paused thread sees a successful CAS.  It's
// essentially an ABA problem. If we use a usize position encoding, the
// likelihood of this happening is essentially nil. On a modern 64-bit machine,
// a thread would have to pause at the wrong point for 2^64 enqueue/dequeue
// operations. Nevertheless, this is very subtle and thanks to Zig's flexible
// integer sizes we discovered this accidentally.

pub fn ConcurrentArrayQueue(
    comptime T: anytype,
    comptime variant: Variant,
) type {
    return ConcurrentArrayQueueImpl(T, usize, variant);
}

fn ConcurrentArrayQueueImpl(
    comptime T: anytype,
    comptime IndexT: anytype,
    comptime variant: Variant,
) type {
    return struct {
        const Self = @This();

        const Index = IndexT;
        const SignedIndex = std.meta.Int(.signed, std.meta.bitCount(Index));

        const isMP = variant.multiProducer();
        const isMC = variant.multiConsumer();

        const SequencedItem = struct {
            seq: Atomic(Index),
            val: T,
        };

        items: []SequencedItem align(cache_line_bytes),
        mask: Index, // pre-computed bitmask for getting index from head/tail
        dq_pos: Atomic(Index) align(cache_line_bytes), // dequeued from here
        eq_pos: Atomic(Index) align(cache_line_bytes), // enqueued to here

        pub fn init(alloc: std.mem.Allocator, size: Index) !Self {
            std.debug.assert(std.math.isPowerOfTwo(size));
            var items = try alloc.alloc(SequencedItem, size);
            for (items) |*it, i| {
                it.seq = Atomic(Index).init(@intCast(Index, i));
            }

            return Self{
                .items = items,
                .mask = size - 1,
                .dq_pos = Atomic(Index).init(0),
                .eq_pos = Atomic(Index).init(0),
            };
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            alloc.free(self.items);
        }

        pub fn enqueue(self: *Self, item: T) !void {
            while (true) {
                // read the next enqueue position
                var pos = self.eq_pos.load(.Monotonic);
                var cell = &self.items[pos & self.mask];

                // read the sequence value for that position
                const seq = cell.seq.load(.Acquire);

                const dif = @bitCast(SignedIndex, seq) -% @bitCast(SignedIndex, pos);
                if (dif == 0) {
                    if (tryCAS(&self.eq_pos, pos, pos +% 1, isMP)) {
                        // we've allocated access to this cell successfully
                        cell.val = item;
                        cell.seq.store(pos +% 1, .Release);
                        return;
                    } // else: we're racing, so retry

                    // TODO: other implementations use a busy-loop backoff here.
                    // Write a proper benchmark and test if this is needed.
                    // See https://github.com/stromnov/mc-fastflow/blob/master/ff/MPMCqueues.hpp
                    // and https://github.com/crossbeam-rs/crossbeam/blob/master/crossbeam-queue/src/array_queue.rs
                } else if (dif < 0) {
                    // queue is wrapping - let caller retry or fail
                    return error.QueueFull;
                } // else: we're racing, so retry
            }
        }

        pub fn dequeue(self: *Self) ?T {
            while (true) {
                // read the next dequeue position
                var pos = self.dq_pos.load(.Monotonic);
                var cell = &self.items[pos & self.mask];

                // read the sequence value for that position
                const seq = cell.seq.load(.Acquire);

                const dif = @bitCast(SignedIndex, seq) -% @bitCast(SignedIndex, pos +% 1);
                if (dif == 0) {
                    if (tryCAS(&self.dq_pos, pos, pos +% 1, isMC)) {
                        // we've allocated access to this cell successfully
                        const res = cell.val;
                        cell.seq.store(pos +% self.mask +% 1, .Release);
                        return res;
                    } // else: we're racing, so retry

                    // TODO: other implementations use a busy-loop backoff here.
                    // Write a proper benchmark and test if this is needed.
                    // See https://github.com/stromnov/mc-fastflow/blob/master/ff/MPMCqueues.hpp
                    // and https://github.com/crossbeam-rs/crossbeam/blob/master/crossbeam-queue/src/array_queue.rs
                } else if (dif < 0) {
                    // queue is empty
                    return null;
                } // else: we're racing, so retry
            }
        }

        pub fn empty(self: *Self) bool {
            // read the next dequeue position
            const pos = self.dq_pos.load(.Monotonic);
            const cell = &self.items[pos & self.mask];

            // read the sequence value for that position
            const seq = cell.seq.load(.Acquire);

            const dif = @bitCast(SignedIndex, seq) -% @bitCast(SignedIndex, pos +% 1);

            return (dif < 0);
        }

        inline fn tryCAS(
            x: *Atomic(Index),
            compare: Index,
            exchange: Index,
            comptime concurrent: bool,
        ) bool {
            if (concurrent) {
                return (x.tryCompareAndSwap(compare, exchange, .Monotonic, .Monotonic) == null);
            } else {
                x.store(exchange, .Monotonic);
                return true;
            }
        }
    };
}

pub fn QueueTest(comptime Queue: anytype) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        q: Queue,

        pub fn init(alloc: std.mem.Allocator, size: Queue.Index) !Self {
            return Self{
                .alloc = alloc,
                .q = try Queue.init(alloc, size),
            };
        }

        pub fn deinit(self: *Self) void {
            self.q.deinit(self.alloc);
        }

        pub fn run(
            self: *Self,
            num_producers: usize,
            num_consumers: usize,
            msg_per_producer: usize,
            sleep: bool,
        ) !void {
            var producers = try self.alloc.alloc(std.Thread, num_producers);
            for (producers) |*p, i| {
                p.* = try std.Thread.spawn(
                    .{},
                    producer,
                    .{ &self.q, i, msg_per_producer, sleep },
                );
            }

            defer {
                for (producers) |*p| {
                    p.join();
                }
                self.alloc.free(producers);
            }

            var total = Atomic(usize).init(num_producers * msg_per_producer);

            var consumers = try self.alloc.alloc(std.Thread, num_consumers);
            for (consumers) |*c| {
                c.* = try std.Thread.spawn(
                    .{},
                    consumer,
                    .{ &self.q, &total, sleep },
                );
            }

            defer {
                for (consumers) |*c| {
                    c.join();
                }
                self.alloc.free(consumers);
            }
        }

        fn producer(q: *Queue, tid: usize, count: usize, sleep: bool) void {
            var i: usize = count;
            while (i != 0) {
                if (sleep) std.time.sleep(1);
                if (q.enqueue(tid)) {
                    i -= 1;
                } else |_| {} // else retry
            }
        }

        fn consumer(q: *Queue, total: *Atomic(usize), sleep: bool) void {
            while (total.load(.Monotonic) > 0) {
                if (sleep) std.time.sleep(1);
                if (q.dequeue()) |_| {
                    _ = total.fetchSub(1, .AcqRel);
                }
            }
        }
    };
}

test "concurrent" {
    const alloc = std.testing.allocator;

    const cases = [_]struct {
        producers: usize,
        consumers: usize,
        queue_sz: usize,
        num_msgs: usize,
        sleep: bool,
    }{
        .{ .producers = 1, .consumers = 1, .queue_sz = 8, .num_msgs = 100, .sleep = false },
        .{ .producers = 8, .consumers = 8, .queue_sz = 4, .num_msgs = 100, .sleep = true },
        // .{ .producers = 32, .consumers = 32, .queue_sz = 128, .num_msgs = 100, .sleep = false },
        // .{ .producers = 32, .consumers = 32, .queue_sz = 128, .num_msgs = 100, .sleep = true },
    };

    inline for (cases) |tc| {
        const variant = comptime Variant.fromDescription(
            if (tc.producers == 1) .SP else .MP,
            if (tc.consumers == 1) .SC else .MC,
        );

        // NOTE: testing concurrent access, we want to use the "full" index, and
        // thus the public API version. See note above.
        const Queue = ConcurrentArrayQueue(usize, variant);

        var qt = try QueueTest(Queue).init(alloc, tc.queue_sz);
        defer qt.deinit();

        try qt.run(
            tc.producers,
            tc.consumers,
            tc.num_msgs,
            tc.sleep,
        );
    }
}

test "queue empty and full" {
    const alloc = std.testing.allocator;

    inline for (std.meta.fields(Variant)) |v| {
        const variant = @field(Variant, v.name);
        const Queue = ConcurrentArrayQueueImpl(u32, u2, variant);

        {
            var q = try Queue.init(alloc, 2);
            defer q.deinit(alloc);

            try std.testing.expectEqual(true, q.empty());

            try std.testing.expect(q.dequeue() == null);

            try q.enqueue(0);
            try q.enqueue(1);
            try std.testing.expectError(error.QueueFull, q.enqueue(2));
        }

        {
            var q = try Queue.init(alloc, 2);
            defer q.deinit(alloc);

            // cycle around to exercise wrap-around math
            try q.enqueue(0);
            try std.testing.expectEqual(@intCast(u32, 0), q.dequeue().?);
            try q.enqueue(1);
            try std.testing.expectEqual(@intCast(u32, 1), q.dequeue().?);

            try q.enqueue(2);
            try q.enqueue(3);
            try std.testing.expectError(error.QueueFull, q.enqueue(4));
        }
    }
}
