const std = @import("std");
const vortex = @import("../vortex.zig");

const alloc = std.testing.allocator;

fn test_spawn(comptime V: type) !void {
    const Config = V.Config;
    const Timespec = V.Timespec;
    const SpawnHandle = V.task.SpawnHandle;
    const spawn = V.task.spawn;
    const sleep = V.time.sleep;

    const init = struct {
        fn child(sleep_time: Timespec) !u32 {
            if (sleep_time > 0) try sleep(sleep_time);

            return 42;
        }

        fn start(child_sleep: V.Timespec, timeout: Timespec) !void {
            var ch: SpawnHandle(child) = undefined;
            try spawn(&ch, .{child_sleep}, timeout);

            // If the child_sleep > timeout, this should return TaskTimeout
            const res = try ch.join();

            // Otherwise, we expect to get the answer
            try std.testing.expectEqual(@as(u32, 42), res);
        }
    }.start;

    const timeout = 10 * std.time.ns_per_ms;
    const cases = [_]struct {
        child_sleep: Timespec,
        exp_err: anyerror!void,
    }{
        // zig fmt: off
        .{ .child_sleep = 0,           .exp_err = {}                },
        .{ .child_sleep = 2 * timeout, .exp_err = error.TaskTimeout },
        // zig fmt: on
    };

    for (cases) |tc| {
        try std.testing.expectEqual(
            tc.exp_err, 
            V.testing.runTest(
                alloc, 
                Config{},
                init, 
                .{ tc.child_sleep, timeout},
            ),
        );
    }

}

test "spawn" {
    try test_spawn(vortex.Vortex);
}

// TODO: SimVortex test