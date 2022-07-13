const std = @import("std");
const target = @import("builtin").target;

const scheduler = @import("scheduler.zig");

const DefaultPlatformFactory = switch (target.os.tag) {
    .linux => @import("platform/io_uring.zig").IoUringPlatform,
    // .linux => @import("platform/io_reactor.zig").ReactorPlatform,

    .macos,
    .tvos,
    .watchos,
    .ios,
    => @import("platform/io_reactor.zig").ReactorPlatform,

    else => @compileError("unsupported platform"),
};

pub const DefaultPlatform = DefaultPlatformFactory(scheduler.DefaultScheduler);
pub const SimPlatform = @import("platform/io_sim.zig").SimPlatform;

fn test_sleep(comptime Platform: type) !void {
    const Scheduler = Platform.Scheduler;
    const Clock = Scheduler.Clock;
    const Emitter = @import("event.zig").Emitter(Clock);
    const SyncEventWriter = @import("event.zig").SyncEventWriter;

    const InitTask = struct {
        sched: *Scheduler,
        phase: usize = 0,

        fn start(self: *@This(), platform: *Platform) !void {
            suspend {
                _ = self.sched.spawnInit(@frame());
            }
            defer self.sched.joinInit();

            self.phase = 1;
            try platform.sleep(1);
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

    var platform = try Platform.init(alloc, Platform.Config{}, &sched, &emitter);
    defer platform.deinit(alloc);

    // At first there are no events to complete
    try std.testing.expectEqual(@as(usize, 0), try platform.poll(std.time.ns_per_ms));

    var init_task = InitTask{ .sched = &sched };
    var frame = &async init_task.start(&platform);

    // The init task should have started and suspended immediately
    try std.testing.expectEqual(@as(usize, 0), init_task.phase);

    // One task wakeup
    try std.testing.expectEqual(@as(usize, 1), sched.tick());

    // The init task should now be suspended while sleeping
    try std.testing.expectEqual(@as(usize, 1), init_task.phase);

    // The platform should have one event to process
    try std.testing.expectEqual(@as(usize, 1), try platform.poll(std.time.ns_per_ms));

    // One task wakeup
    try std.testing.expectEqual(@as(usize, 1), sched.tick());

    // The task should be complete
    try std.testing.expectEqual(@as(usize, 2), init_task.phase);

    try nosuspend await frame;
}

test "DefaultPlatform sleep" {
    try test_sleep(DefaultPlatform);
}

// test "SimPlatform sleep" {
//     try test_sleep(SimPlatform);
// }
