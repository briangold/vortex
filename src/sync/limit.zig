//! Concurrent counter up to a limit
const std = @import("std");
const builtin = @import("builtin");

pub fn LimitCounter(comptime T: type) type {
    return struct {
        const Self = @This();
        const Counter = T;
        const AtomicCounter = std.atomic.Atomic(T);

        val: AtomicCounter,
        limit: Counter,

        pub fn init(limit: Counter) Self {
            return Self{
                .val = AtomicCounter.init(0),
                .limit = limit,
            };
        }

        /// Increment counter, returning new value or null if already at limit
        pub fn inc(lc: *Self) ?Counter {
            while (true) {
                const c = lc.val.load(.Monotonic);
                if (c == lc.limit) return null;
                if (lc.tryCAS(c, c + 1)) return c + 1;
            }
        }

        /// Decrement counter, returning new value or null if already at 0
        pub fn dec(lc: *Self) ?Counter {
            while (true) {
                const c = lc.val.load(.Monotonic);
                if (c == 0) return null;
                if (lc.tryCAS(c, c - 1)) return c - 1;
            }
        }

        fn tryCAS(lc: *Self, exp: Counter, new: Counter) bool {
            return lc.val.tryCompareAndSwap(exp, new, .Release, .Monotonic) == null;
        }
    };
}

test "LimitCounter single thread" {
    var lc = LimitCounter(usize).init(2);
    try std.testing.expectEqual(@as(?usize, 1), lc.inc());
    try std.testing.expectEqual(@as(?usize, 2), lc.inc());
    try std.testing.expectEqual(@as(?usize, null), lc.inc());

    try std.testing.expectEqual(@as(?usize, 1), lc.dec());
    try std.testing.expectEqual(@as(?usize, 0), lc.dec());
    try std.testing.expectEqual(@as(?usize, null), lc.dec());
}

test "LimitCounter concurrent" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Limit = LimitCounter(usize);

    const worker = struct {
        fn run(lc: *Limit, id: usize, num_iter: usize) void {
            // even threads increment, odd decrement
            const fun = if (id % 2 == 0) Limit.inc else Limit.dec;

            var i = num_iter;
            while (i > 0) : (i -= 1) {
                while (fun(lc) == null) {
                    // not necessary, but randomizes schedule a bit
                    std.time.sleep(0);
                }
            }
        }
    }.run;

    const num_threads = 4;
    const num_iter = 1000;

    var lc = Limit.init(num_threads);

    const alloc = std.testing.allocator;
    var workers = try alloc.alloc(std.Thread, num_threads);
    defer alloc.free(workers);

    for (workers) |*w, i| {
        w.* = try std.Thread.spawn(
            .{},
            worker,
            .{ &lc, i, num_iter },
        );
    }

    for (workers) |*w| {
        w.join();
    }
}
