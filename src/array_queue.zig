//! Concurrent, bounded, array-backed queues. Based on the implementation from
//! Erik Rigtorp (https://github.com/rigtorp/MPMCQueue), available under MIT
//! license. Changed to require power-of-2 capacity, relaxed memory ordering,
//! and narrower index types for test cases.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const Ordering = std.atomic.Ordering;
const cache_line_bytes = std.atomic.cache_line;

/// Returns the concrete type of the queue holding type T. This public API
/// uses a u32 type for the queue's internal Index, safe for use in practice
/// and compatible with Futex operations.
pub fn ConcurrentArrayQueue(comptime T: type) type {
    return ConcurrentArrayQueueImpl(T, u32, std.atomic.Atomic(u32));
}

/// The internal implementation, with narrower Index types, is useful for
/// testing wraparound conditions. But concurrent accesses that wrap are
/// vulnerable to subtle ABA problems in the queue, so for practical uses we
/// expose only the wider-indexed version in ConcurrentArrayQueue.
fn ConcurrentArrayQueueImpl(
    comptime T: type,
    comptime I: type,
    comptime AtomicIndex: type,
) type {
    const index_info = @typeInfo(I).Int;
    comptime {
        assert(index_info.signedness == .unsigned);
        assert(index_info.bits > 0 and index_info.bits <= @typeInfo(usize).Int.bits);
    }

    const Slot = struct {
        turn: AtomicIndex align(cache_line_bytes),
        data: T align(cache_line_bytes),
    };

    comptime assert(@alignOf(Slot) == cache_line_bytes);
    comptime assert(@sizeOf(Slot) % cache_line_bytes == 0);

    return struct {
        const Queue = @This();
        const Index = I;

        mask: Index, // capacity - 1
        shift: std.math.Log2Int(Index), // log2(capacity)
        slots: []Slot,
        head: AtomicIndex align(cache_line_bytes),
        tail: AtomicIndex align(cache_line_bytes),

        /// Constructs a queue using alloc to create the underlying array.
        /// Requires capacity to be a non-zero power of two.
        pub fn init(alloc: std.mem.Allocator, capacity: Index) !Queue {
            if (capacity == 0 or !std.math.isPowerOfTwo(capacity)) {
                return error.BadQueueCapacity;
            }

            // alloc an extra slot to prevent false sharing on the last slot
            var slots = try alloc.alloc(Slot, capacity + 1);
            for (slots) |*s| {
                s.* = Slot{
                    .turn = AtomicIndex.init(0),
                    .data = undefined,
                };
            }

            return Queue{
                .mask = capacity - 1,
                .shift = std.math.log2_int(Index, capacity),
                .slots = slots,
                .head = AtomicIndex.init(0),
                .tail = AtomicIndex.init(0),
            };
        }

        pub fn deinit(queue: *Queue, alloc: std.mem.Allocator) void {
            alloc.free(queue.slots);
        }

        /// Push an element onto the queue, potentially blocking until space
        /// is available. Use with caution!
        pub fn push(queue: *Queue, item: T) void {
            const head = queue.head.fetchAdd(1, .Monotonic);
            const slot = &queue.slots[queue.idx(head)];
            while (2 *% queue.turn(head) != slot.turn.load(.Acquire)) {
                // blocking
            }
            slot.data = item;
            slot.turn.store(2 *% queue.turn(head) +% 1, .Release);
        }

        /// Pop an element from the queue, potentially blocking on an empty
        /// queue until a new element is available. Use with caution!
        pub fn pop(queue: *Queue) T {
            const tail = queue.tail.fetchAdd(1, .Monotonic);
            const slot = &queue.slots[queue.idx(tail)];
            while (2 *% queue.turn(tail) +% 1 != slot.turn.load(.Acquire)) {
                // blocking
            }
            const v = slot.data;
            slot.data = undefined;
            slot.turn.store(2 *% queue.turn(tail) +% 2, .Release);
            return v;
        }

        /// Attempt to push item into the queue, returning true if successful
        /// and false otherwise.
        pub fn try_push(queue: *Queue, item: T) bool {
            var head = queue.head.load(.Monotonic);
            while (true) {
                const slot = &queue.slots[queue.idx(head)];
                const sturn = slot.turn.load(.Acquire);
                if (2 *% queue.turn(head) == sturn) {
                    if (queue.head.tryCompareAndSwap(head, head +% 1, .Monotonic, .Monotonic) == null) {
                        // NOTE: at this point, the head is updated, but until the
                        // slot.turn location is written, this thread is effectively
                        // holding a "lock" that can cause other threads to wait when
                        // they see the old turn. Only after the slot.turn.write()
                        // completes has the push completed.
                        slot.data = item;
                        const next = 2 *% queue.turn(head) +% 1;
                        slot.turn.store(next, .Release);
                        return true;
                    }
                } else {
                    const prev = head;
                    head = queue.head.load(.Monotonic);
                    if (head == prev) return false;
                }
            }
        }

        /// Attempt to pop an item from the queue, returning the value if
        /// successful and null otherwise.
        pub fn try_pop(queue: *Queue) ?T {
            var tail = queue.tail.load(.Monotonic);
            while (true) {
                const slot = &queue.slots[queue.idx(tail)];
                const sturn = slot.turn.load(.Acquire);
                if (2 *% queue.turn(tail) +% 1 == sturn) {
                    if (queue.tail.tryCompareAndSwap(tail, tail +% 1, .Monotonic, .Monotonic) == null) {
                        // NOTE: at this point, the tail is updated, but until the
                        // slot.turn location is written, this thread is effectively
                        // holding a "lock" that can cause other threads to wait when
                        // they see the old turn. Only after the slot.turn.write()
                        // completes has the pop completed.
                        const v = slot.data;
                        const next = 2 *% queue.turn(tail) +% 2;
                        slot.data = undefined; // 0xaaaaa... in Debug builds
                        slot.turn.store(next, .Release);
                        return v;
                    }
                } else {
                    const prev = tail;
                    tail = queue.tail.load(.Monotonic);
                    if (tail == prev) return null;
                }
            }
        }

        pub fn size(queue: *Queue) Index {
            return queue.head.load(.Monotonic) -% queue.tail.load(.Monotonic);
        }

        pub fn empty(queue: *Queue) bool {
            return queue.size() == 0;
        }

        fn idx(queue: *Queue, i: Index) Index {
            return i & queue.mask;
        }

        fn turn(queue: *Queue, i: Index) Index {
            return i >> queue.shift;
        }
    };
}

test "queue" {
    const alloc = std.testing.allocator;

    const I = u2;

    const MockAtomicIndex = struct {
        const Self = @This();

        v: I,

        fn init(v: I) Self {
            comptime if (!builtin.is_test)
                @compileError("Illegal use of ConcurrentArrayQueueImpl");
            return .{ .v = v };
        }

        fn load(ai: *Self, comptime _: Ordering) I {
            return ai.v;
        }

        fn store(ai: *Self, val: I, comptime _: Ordering) void {
            ai.v = val;
        }

        fn tryCompareAndSwap(
            ai: *Self,
            exp: I,
            new: I,
            comptime _: Ordering,
            comptime _: Ordering,
        ) ?I {
            if (ai.v == exp) {
                ai.v = new;
                return null;
            } else {
                return ai.v;
            }
        }

        fn fetchAdd(ai: *Self, amt: I, comptime _: Ordering) I {
            const prev = ai.v;
            ai.v = prev +% amt;
            return prev;
        }
    };

    const Q = ConcurrentArrayQueueImpl(u8, I, MockAtomicIndex);
    try std.testing.expectError(error.BadQueueCapacity, Q.init(alloc, 0));
    try std.testing.expectError(error.BadQueueCapacity, Q.init(alloc, 3));

    var q = try Q.init(alloc, 2);
    defer q.deinit(alloc);

    try std.testing.expectEqual(true, q.empty());
    try std.testing.expectEqual(true, q.try_push(42));
    try std.testing.expectEqual(@as(u8, 1), q.size());
    try std.testing.expectEqual(false, q.empty());
    try std.testing.expectEqual(@as(?u8, 42), q.try_pop());
    try std.testing.expectEqual(true, q.empty());

    try std.testing.expectEqual(true, q.try_push(1));
    try std.testing.expectEqual(true, q.try_push(2));
    try std.testing.expectEqual(false, q.try_push(3));
    try std.testing.expectEqual(@as(u8, 2), q.size());
    try std.testing.expectEqual(@as(?u8, 1), q.try_pop());
    try std.testing.expectEqual(false, q.empty());
    try std.testing.expectEqual(@as(?u8, 2), q.try_pop());
    try std.testing.expectEqual(true, q.empty());
    try std.testing.expectEqual(@as(?u8, null), q.try_pop());
    try std.testing.expectEqual(true, q.empty());

    q.push(42);
    try std.testing.expectEqual(@as(u8, 1), q.size());
    try std.testing.expectEqual(@as(u8, 42), q.pop());
    try std.testing.expectEqual(true, q.empty());

    q.push(1);
    q.push(2);
    try std.testing.expectEqual(@as(u8, 2), q.size());
    try std.testing.expectEqual(@as(u8, 1), q.pop());
    try std.testing.expectEqual(@as(u8, 1), q.size());
    try std.testing.expectEqual(@as(u8, 2), q.pop());
    try std.testing.expectEqual(true, q.empty());
}

/// Test harness - runs a set of producer and consumer threads. Producers push
/// sequential integers and consumers sum what they receive locally, then merge
/// for a final sum that tests whether all values were received.
fn QueueTestConcurrent(comptime Queue: type) type {
    return struct {
        const Self = @This();

        queue: *Queue,
        start: bool = false,
        sum: u64 = 0,

        fn run(qt: *Self, num_threads: usize, num_ops: usize) !u64 {
            const alloc = std.testing.allocator;

            std.debug.assert(num_threads > 0 and num_threads % 2 == 0);
            const producer_count = num_threads / 2;
            const consumer_count = num_threads / 2;

            var producers = try alloc.alloc(std.Thread, producer_count);
            for (producers) |*p, i| {
                p.* = try std.Thread.spawn(
                    .{},
                    producer,
                    .{ qt.queue, i, &qt.start, num_ops, producer_count },
                );
            }

            var consumers = try alloc.alloc(std.Thread, consumer_count);
            for (consumers) |*c, i| {
                c.* = try std.Thread.spawn(
                    .{},
                    consumer,
                    .{ qt.queue, i, &qt.start, num_ops, consumer_count, &qt.sum },
                );
            }

            @atomicStore(bool, &qt.start, true, .SeqCst);

            for (producers) |*p| {
                p.join();
            }
            alloc.free(producers);

            for (consumers) |*c| {
                c.join();
            }
            alloc.free(consumers);

            return @atomicLoad(u64, &qt.sum, .SeqCst);
        }

        fn producer(
            q: *Queue,
            tid: usize,
            start: *bool,
            num_ops: usize,
            num_producers: usize,
        ) void {
            while (!@atomicLoad(bool, start, .SeqCst)) {}

            var j: usize = tid;
            while (j < num_ops) : (j += num_producers) {
                q.push(j);
            }
        }

        fn consumer(
            q: *Queue,
            tid: usize,
            start: *bool,
            num_ops: usize,
            num_consumers: usize,
            sum: *u64,
        ) void {
            while (!@atomicLoad(bool, start, .SeqCst)) {}

            var thread_sum: u64 = 0;
            var j: usize = tid;
            while (j < num_ops) : (j += num_consumers) {
                thread_sum += q.pop();
            }

            _ = @atomicRmw(u64, sum, .Add, thread_sum, .SeqCst);
        }
    };
}

test "queue concurrent" {
    const alloc = std.testing.allocator;

    const Q = ConcurrentArrayQueue(u64);

    const num_ops = 100;
    const num_threads = 4;

    var q = try Q.init(alloc, num_threads);
    defer q.deinit(alloc);

    var qt = QueueTestConcurrent(Q){ .queue = &q };
    const sum = try qt.run(num_threads, num_ops);

    try std.testing.expectEqual(@as(u64, num_ops * (num_ops - 1) / 2), sum);
}

pub fn QueueCycleTest(comptime Queue: anytype) type {
    return struct {
        const Self = @This();

        queue: *Queue,

        pub fn run(
            qct: *Self,
            num_threads: usize,
            num_ops: usize,
        ) !void {
            const alloc = std.testing.allocator;

            var workers = try alloc.alloc(std.Thread, num_threads);
            defer alloc.free(workers);

            for (workers) |*w| {
                w.* = try std.Thread.spawn(
                    .{},
                    worker,
                    .{ qct, num_ops },
                );
            }

            for (workers) |*w| {
                w.join();
            }
        }

        fn worker(qct: *Self, num_ops: usize) void {
            var i = num_ops;
            while (i != 0) : (i -= 1) {
                const item = dq: {
                    while (true) {
                        if (qct.queue.try_pop()) |x| {
                            break :dq x;
                        }
                    }
                };

                // Use blocking push - we know it will succeed, but in case
                // another thread is slow in the critical section of try_pop()
                // we will block this thread. Forward progress is guaranteed,
                // as long as the OS eventually schedules the critical-section
                // holder. See comment in try_push()
                qct.queue.push(item);
            }
        }
    };
}

// Keeps a bounded amount of work in the system by repeatedly dequeuing before
// enqueuing an item. Test that we never have overflow.
test "concurrent recycling" {
    const alloc = std.testing.allocator;

    const cases = [_]struct {
        queue_sz: usize,
        num_threads: usize,
        num_ops: usize,
    }{
        .{ .queue_sz = 2, .num_threads = 2, .num_ops = 1000 },
    };

    inline for (cases) |tc| {
        // NOTE: testing concurrent access, we want to use the "full" index, and
        // thus the public API version. See note above.
        const Queue = ConcurrentArrayQueue(usize);

        var q = try Queue.init(alloc, tc.queue_sz);
        defer q.deinit(alloc);

        // push queue_size items in to start
        var i = tc.queue_sz;
        while (i != 0) : (i -= 1) {
            if (!q.try_push(i)) @panic("can't populate initial queue");
        }

        var qt = QueueCycleTest(Queue){ .queue = &q };
        try qt.run(tc.num_threads, tc.num_ops);
    }
}

// Small helper to find the next power-of-two above some minimum, but unlike
// std.math.ceilPowerOfTwo, works on comptime_int so we can build an Int type
// from the returned bit count.
fn nextPowerOfTwoComptime(
    comptime v: comptime_int,
    comptime min: comptime_int,
) comptime_int {
    assert(v > 0);
    assert(v <= 64);

    var p: comptime_int = min;
    inline while (p < v) p <<= 1;

    return p;
}

test "nextPowerOfTwoComptime" {
    // turn a u1 into a u8
    try std.testing.expectEqual(8, nextPowerOfTwoComptime(1, 8));

    // a u8 should just be a u8
    try std.testing.expectEqual(8, nextPowerOfTwoComptime(8, 8));

    // etc.
    try std.testing.expectEqual(16, nextPowerOfTwoComptime(9, 8));
    try std.testing.expectEqual(16, nextPowerOfTwoComptime(16, 8));
    try std.testing.expectEqual(32, nextPowerOfTwoComptime(17, 8));
    try std.testing.expectEqual(32, nextPowerOfTwoComptime(32, 8));
    try std.testing.expectEqual(64, nextPowerOfTwoComptime(33, 8));
    try std.testing.expectEqual(64, nextPowerOfTwoComptime(64, 8));
}
