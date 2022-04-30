const std = @import("std");
const vx = @import("vortex").Vortex;
const assert = std.debug.assert;

const ztracy = @import("ztracy");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (@import("builtin").mode == .Debug) {
        std.debug.assert(!gpa.deinit());
    };

    const InitTask = struct {
        fn subtask(val: usize) !usize {
            ztracy.Message("Init subtask");

            vx.event.emit(SubtaskStartEvent, .{ .val = val });

            const interval = @intCast(vx.Timespec, val);
            try vx.time.sleep(interval * std.time.ns_per_ms);

            vx.event.emit(SubtaskFinishEvent, .{});
            return val;
        }

        fn start() !void {
            vx.event.emit(InitStartEvent, .{});

            std.time.sleep(10 * std.time.ns_per_s);

            const Handle = vx.task.SpawnHandle(subtask);
            var tasks = [1]Handle{undefined} ** 4;

            for (tasks) |*t, i| {
                try vx.task.spawn(t, .{i + 1}, null);
            }

            var result: usize = 0;
            for (tasks) |*t| {
                result += try t.join();
            }

            vx.event.emit(InitFinishEvent, .{ .result = result });
        }
    };

    const alloc = gpa.allocator();

    try vx.init(alloc, vx.DefaultTestConfig);
    defer vx.deinit(alloc);

    try vx.run(InitTask.start, .{});
}

const ScopedRegistry = vx.event.Registry("demo.one", enum {
    subtask_start,
    subtask_finish,
    init_start,
    init_finish,
});

const SubtaskStartEvent = ScopedRegistry.register(.subtask_start, .info, struct { val: usize });
const SubtaskFinishEvent = ScopedRegistry.register(.subtask_finish, .info, struct {});
const InitStartEvent = ScopedRegistry.register(.init_start, .info, struct {});
const InitFinishEvent = ScopedRegistry.register(.init_finish, .info, struct { result: usize });
