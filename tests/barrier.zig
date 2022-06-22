const std = @import("std");
const vortex = @import("../vortex.zig");
const Atomic = std.atomic.Atomic;

const alloc = std.testing.allocator;

fn test_barrier(comptime V: type) !void {
    const Barrier = V.sync.Barrier;
    const SpawnHandle = V.task.SpawnHandle;
    const spawn = V.task.spawn;

    const num_tasks = 8;
    const num_phases = 100;

    const init = struct {
        fn sync_task(barrier: *Barrier) !void {
            var i: usize = 0;
            while (i < num_phases) : (i += 1) {
                try barrier.wait(null);
            }
        }

        fn start() !void {
            var tasks: [num_tasks]SpawnHandle(sync_task) = undefined;

            var barrier = Barrier{ .num_tasks = num_tasks };
            for (tasks) |*t| try spawn(t, .{&barrier}, std.time.ns_per_s);
            for (tasks) |*t| _ = try t.join();
        }
    }.start;

    try V.testing.runTest(alloc, V.DefaultTestConfig, init, .{});
}

test "barrier" {
    try test_barrier(vortex.Vortex);
}
