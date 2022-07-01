const std = @import("std");
const vortex = @import("../vortex.zig");
const Atomic = std.atomic.Atomic;

const alloc = std.testing.allocator;

fn test_barrier(comptime V: type) !void {
    const Barrier = V.sync.Barrier;
    const SpawnHandle = V.task.SpawnHandle;
    const spawn = V.task.spawn;
    const emit = V.event.emit;

    const ScopedRegistry = V.event.Registry("test.barrier", enum {
        iteration_start,
        iteration_end,
    });

    const IterationStart = ScopedRegistry.register(
        .iteration_start,
        .debug,
        struct { i: usize, id: usize },
    );

    const IterationEnd = ScopedRegistry.register(
        .iteration_end,
        .debug,
        struct { i: usize, id: usize },
    );

    const num_tasks = 8;
    const num_phases = 100;

    const init = struct {
        fn sync_task(barrier: *Barrier) !void {
            var i: usize = 0;
            while (i < num_phases) : (i += 1) {
                emit(IterationStart, .{ .id = V.task.id(), .i = i });
                try barrier.wait(null);
                emit(IterationEnd, .{ .id = V.task.id(), .i = i });
            }
        }

        fn start() !void {
            var tasks: [num_tasks]SpawnHandle(sync_task) = undefined;

            var barrier = Barrier{ .num_tasks = num_tasks };
            for (tasks) |*t| try spawn(t, .{&barrier}, null);
            for (tasks) |*t| _ = try t.join();
        }
    }.start;

    try V.testing.runTest(alloc, V.DefaultTestConfig, init, .{});
}

test "barrier" {
    try test_barrier(vortex.Vortex);
}
