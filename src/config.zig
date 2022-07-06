const std = @import("std");

pub fn Config(comptime Runtime: type) type {
    return struct {
        const SchedulerConfig = @import("scheduler.zig").Config;
        const SyncEventWriter = @import("event.zig").SyncEventWriter;
        const PlatformConfig = Runtime.Platform.Config;

        const Self = @This();

        /// I/O engine configuration
        platform: PlatformConfig = PlatformConfig{},

        /// Scheduler configuration
        scheduler: SchedulerConfig = SchedulerConfig{},

        /// Number of dedicated task threads to spawn. If set to 0, the runtime
        /// is configured to be single-threaded, where task execution shares
        /// time with the I/O thread. When non-zero, the runtime will spawn that
        /// many worker threads to schedule task execution across, and the I/O
        /// thread will only process I/O events.
        task_threads: usize = 4,

        /// The synchronized `writer' object for writing event records (logs).
        event_writer: SyncEventWriter = .{
            .writer = std.io.getStdErr().writer(),
            .mutex = std.debug.getStderrMutex(),
        },

        /// The logging level, using the std logging level definitions
        log_level: std.log.Level = .info,
    };
}
