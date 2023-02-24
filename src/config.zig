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

        /// Total number of threads for the runtime for task execution.
        task_threads: usize = 4,

        /// The synchronized `writer' object for writing event records (logs).
        event_writer: SyncEventWriter = .{
            .writer = std.io.getStdErr().writer(),
            .mutex = std.debug.getStderrMutex(),
        },

        /// The logging level, using the std logging level definitions
        log_level: std.log.Level = .debug,
    };
}
