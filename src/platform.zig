const std = @import("std");
const target = @import("builtin").target;

const scheduler = @import("scheduler.zig");

const DefaultLoopFactory = switch (target.os.tag) {
    .linux => @import("platform/io_uring.zig").LoopFactory,
    // .linux => @import("platform/io_reactor.zig").LoopFactory,

    .macos,
    .tvos,
    .watchos,
    .ios,
    => @import("platform/io_reactor.zig").LoopFactory,

    else => @compileError("unsupported platform"),
};

pub const DefaultLoop = DefaultLoopFactory(scheduler.DefaultScheduler);
pub const SimIoLoop = @import("platform/io_sim.zig").SimIoLoop;

fn test_sleep(comptime Loop: type) !void {
    const Scheduler = Loop.Scheduler;
    const Clock = Scheduler.Clock;
    const Emitter = @import("event.zig").Emitter;
    const SyncEventWriter = @import("event.zig").SyncEventWriter;

    const InitTask = struct {
        sched: *Scheduler,
        phase: usize = 0,

        fn start(self: *@This(), loop: *Loop) !void {
            suspend {
                _ = self.sched.spawnInit(@frame());
            }
            defer self.sched.joinInit();

            self.phase = 1;
            try loop.sleep(1);
            self.phase = 2;
        }
    };

    const alloc = std.testing.allocator;

    var clk = Clock{};

    const sync_writer = SyncEventWriter{
        .writer = std.io.getStdErr().writer(),
        .mutex = std.debug.getStderrMutex(),
    };

    var emitter = Emitter.init(.info, sync_writer);

    var sched = try Scheduler.init(alloc, &clk, &emitter, .{ .max_tasks = 2 });
    defer sched.deinit(alloc);

    var loop = try Loop.init(alloc, Loop.Config{}, &sched, &emitter);
    defer loop.deinit(alloc);

    // At first there are no events to complete
    try std.testing.expectEqual(@as(usize, 0), try loop.poll(std.time.ns_per_ms));

    var init_task = InitTask{ .sched = &sched };
    var frame = &async init_task.start(&loop);

    // The init task should have started and suspended immediately
    try std.testing.expectEqual(@as(usize, 0), init_task.phase);

    // One task wakeup
    try std.testing.expectEqual(@as(usize, 1), sched.tick());

    // The init task should now be suspended while sleeping
    try std.testing.expectEqual(@as(usize, 1), init_task.phase);

    // The loop should have one event to process
    try std.testing.expectEqual(@as(usize, 1), try loop.poll(std.time.ns_per_ms));

    // One task wakeup
    try std.testing.expectEqual(@as(usize, 1), sched.tick());

    // The task should be complete
    try std.testing.expectEqual(@as(usize, 2), init_task.phase);

    try nosuspend await frame;
}

test "DefaultLoop sleep" {
    try test_sleep(DefaultLoop);
}

// test "SimIoLoop sleep" {
//     try test_sleep(SimIoLoop);
// }
