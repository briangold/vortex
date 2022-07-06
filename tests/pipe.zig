const std = @import("std");
const os = std.os;

const vortex = @import("../vortex.zig");

const alloc = std.testing.allocator;

fn test_pipe(comptime V: type) !void {
    const PipePair = V.ipc.PipePair;
    const SpawnHandle = V.task.SpawnHandle;
    const spawn = V.task.spawn;

    const msg = "this is a test message";

    const init = struct {
        fn reader(pipe: PipePair) !void {
            var buf: [msg.len]u8 = undefined;
            const c = try pipe.read(&buf, null);

            try std.testing.expectEqual(msg.len, c);
            try std.testing.expectEqualSlices(u8, &buf, msg);
        }

        fn writer(pipe: PipePair) !void {
            const c = try pipe.write(msg, null);
            try std.testing.expectEqual(msg.len, c);
        }

        fn start() !void {
            var pipe = try V.ipc.openPipe();
            defer pipe.deinit();

            var rd: SpawnHandle(reader) = undefined;
            var wr: SpawnHandle(writer) = undefined;
            try spawn(&rd, .{pipe}, null);
            try spawn(&wr, .{pipe}, null);
            try rd.join();
            try wr.join();
        }
    }.start;

    try V.testing.runTest(alloc, V.DefaultTestConfig, init, .{});
}

test "pipe" {
    try test_pipe(vortex.Vortex);
}
