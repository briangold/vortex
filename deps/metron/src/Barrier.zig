//! A simple barrier that self-resets after each sync phase is complete.
//! Based on the original one-time barrier in std.Thread.Futex test case.

const std = @import("std");
const builtin = @import("builtin");

const Atomic = std.atomic.Atomic;
const Futex = std.Thread.Futex;

const Barrier = @This();

num_threads: u32,
entered: Atomic(u32) = Atomic(u32).init(0),
phase: Atomic(u32) = Atomic(u32).init(0), // futex variable

pub fn wait(b: *Barrier) void {
    const prev_phase = b.phase.load(.Acquire);
    const prev_count = b.entered.fetchAdd(1, .AcqRel);
    std.debug.assert(prev_count < b.num_threads);
    std.debug.assert(prev_count >= 0);

    // last to arrive wakes all others and sets up next phase
    if (prev_count + 1 == b.num_threads) {
        b.entered.store(0, .Release);
        b.phase.store(prev_phase + 1, .Release);
        Futex.wake(&b.phase, b.num_threads - 1);
        return;
    }

    // wait for phase change
    while (b.phase.load(.Acquire) == prev_phase) {
        Futex.wait(&b.phase, prev_phase);
    }
}

test "barrier" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const num_threads = 8;
    const num_phases = 10;

    const Context = struct {
        barrier: Barrier = Barrier{ .num_threads = num_threads },
        threads: [num_threads]std.Thread = undefined,

        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < num_phases) : (i += 1) {
                self.barrier.wait();
            }
        }
    };

    var ctx = Context{};
    for (ctx.threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    }
    for (ctx.threads) |t| t.join();
}
