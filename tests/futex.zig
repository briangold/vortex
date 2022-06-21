const std = @import("std");
const vortex = @import("../vortex.zig");
const Atomic = std.atomic.Atomic;

const alloc = std.testing.allocator;

fn test_futex(comptime V: type) !void {
    const Timespec = V.Timespec;
    const SpawnHandle = V.task.SpawnHandle;
    const spawn = V.task.spawn;
    const sleep = V.time.sleep;
    const futex = V.sync.futex;

    const init = struct {
        fn child(ptr: *const Atomic(u32), pre_wait_time: Timespec) !void {
            try sleep(pre_wait_time);
            try futex.wait(ptr, 0, null);

            try std.testing.expectEqual(@as(u32, 1), ptr.load(.SeqCst));
        }

        fn start(pre_wait_time: Timespec, pre_wake_time: Timespec) !void {
            var x = Atomic(u32).init(0);

            // A 1ns timeout on wait should error back
            try std.testing.expectError(error.Timeout, futex.wait(&x, 0, 1));

            var ch: SpawnHandle(child) = undefined;
            try spawn(&ch, .{ &x, pre_wait_time }, null);

            // force different task orderings
            try sleep(pre_wake_time);

            x.store(1, .SeqCst);
            futex.wake(&x, 1);

            _ = try ch.join();
        }
    }.start;

    const cases = [_]struct {
        pre_wait_time: Timespec,
        pre_wake_time: Timespec,
    }{
        // zig fmt: off
        .{ .pre_wait_time = 0,                  .pre_wake_time = 0                  },
        .{ .pre_wait_time = 0,                  .pre_wake_time = std.time.ns_per_ms },
        .{ .pre_wait_time = std.time.ns_per_ms, .pre_wake_time = 0                  },
        .{ .pre_wait_time = std.time.ns_per_ms, .pre_wake_time = std.time.ns_per_ms },
        // zig fmt: on
    };

    for (cases) |tc| {
        try V.testing.runTest(
            alloc,
            V.DefaultTestConfig,
            init,
            .{ tc.pre_wait_time, tc.pre_wake_time },
        );
    }
}

test "futex" {
    try test_futex(vortex.Vortex);
}
