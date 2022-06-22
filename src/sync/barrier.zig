//! A simple barrier that self-resets after each sync phase is complete.
//! Based on the original one-time barrier in std.Thread.Futex test case.

const std = @import("std");
const builtin = @import("builtin");

const Atomic = std.atomic.Atomic;
const futex = @import("../../vortex.zig").sync.futex;

const clock = @import("../clock.zig");
const Timespec = clock.Timespec;

pub fn Barrier(comptime Futex: type) type {
    return struct {
        const Self = @This();

        num_tasks: u32,
        entered: Atomic(u32) = Atomic(u32).init(0),
        phase: Atomic(u32) = Atomic(u32).init(0), // futex variable

        pub fn wait(b: *Self, maybe_timeout: ?Timespec) !void {
            const prev_phase = b.phase.load(.Acquire);
            const prev_count = b.entered.fetchAdd(1, .AcqRel);
            std.debug.assert(prev_count < b.num_tasks);
            std.debug.assert(prev_count >= 0);

            // last to arrive wakes all others and sets up next phase
            if (prev_count + 1 == b.num_tasks) {
                b.entered.store(0, .Release);
                b.phase.store(prev_phase + 1, .Release);
                Futex.wake(&b.phase, b.num_tasks - 1);
                return;
            }

            // wait for phase change
            while (b.phase.load(.Acquire) == prev_phase) {
                try Futex.wait(&b.phase, prev_phase, maybe_timeout);
            }
        }
    };
}
