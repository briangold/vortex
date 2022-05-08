const std = @import("std");
const vortex = @import("../vortex.zig");

const alloc = std.testing.allocator;

fn test_timer(comptime V: type, comptime is_sim: bool) !void {
    const init = struct {
        fn start() !void {
            const begin = V.time.now();

            const interval: V.Timespec = std.time.ns_per_ms;
            try V.time.sleep(interval);

            const end = V.time.now();

            if (is_sim) {
                // With an mock timer, this should be exact
                try std.testing.expectEqual(interval, end - begin);
            } else {
                // With a real clock, there's not much we can say about the
                // timing other than it must be more than the sleep time
                try std.testing.expect(end - begin > interval);
            }
        }
    }.start;

    try V.testing.runTest(alloc, V.DefaultTestConfig, init, .{});
}

test "real timer" {
    try test_timer(vortex.Vortex, false);
}
