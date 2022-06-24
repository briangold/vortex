const std = @import("std");
const vortex = @import("../vortex.zig");

const alloc = std.testing.allocator;

fn test_select(comptime V: type) !void {
    const Timespec = V.Timespec;
    const SpawnHandle = V.task.SpawnHandle;
    const spawn = V.task.spawn;
    const select = V.task.select;
    const sleep = V.time.sleep;

    const init = struct {
        fn child1(timeout: Timespec) !u32 {
            if (timeout != 0) try sleep(timeout);
            return 42;
        }

        fn child2(timeout: Timespec) !void {
            if (timeout != 0) try sleep(timeout);
            return error.ChildError;
        }

        fn start(sleep1: Timespec, sleep2: Timespec) !void {
            var t1: SpawnHandle(child1) = undefined;
            var t2: SpawnHandle(child2) = undefined;

            try spawn(&t1, .{sleep1}, null);
            try spawn(&t2, .{sleep2}, null);

            // Allow sleepX=0 tasks to complete so we exercise paths where a
            // finished task before select() is called.
            try sleep(0);

            const r = try select(.{
                .ch1 = &t1,
                .ch2 = &t2,
            });

            if (sleep1 < sleep2) {
                try std.testing.expect(r == .ch1);
                try std.testing.expectEqual(@as(u32, 42), try r.ch1);
            } else if (sleep1 > sleep2) {
                try std.testing.expect(r == .ch2);
                try std.testing.expectError(error.ChildError, r.ch2);
            } else {
                // We can't say much about the result, but include this
                // racy test for additional coverage.
            }
        }
    }.start;

    const cases = [_]struct {
        sleep1: Timespec,
        sleep2: Timespec,
    }{
        // zig fmt: off
        .{ .sleep1 = std.time.ns_per_ms, .sleep2 = std.time.ns_per_s  },
        .{ .sleep1 = std.time.ns_per_s,  .sleep2 = std.time.ns_per_ms },
        .{ .sleep1 = 0,                  .sleep2 = std.time.ns_per_s  },
        .{ .sleep1 = std.time.ns_per_s,  .sleep2 = 0                  },
        .{ .sleep1 = std.time.ns_per_ms, .sleep2 = std.time.ns_per_ms },
        .{ .sleep1 = 0,                  .sleep2 = 0                  },
        // zig fmt: on
    };

    for (cases) |tc| {
        try V.testing.runTest(
            alloc,
            V.DefaultTestConfig,
            init,
            .{ tc.sleep1, tc.sleep2 },
        );
    }
}

test "select" {
    try test_select(vortex.Vortex);
}