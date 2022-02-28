const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const vortex = if (builtin.is_test)
    @import("../vortex.zig")
else
    @import("vortex");

const alloc = std.testing.allocator;

fn test_basic(comptime V: type) !void {
    const Timespec = V.Timespec;
    const SpawnHandle = V.task.SpawnHandle;
    const spawn = V.task.spawn;
    const sleep = V.time.sleep;
    const now = V.time.now;

    const init = struct {
        fn tocancel(timeout: Timespec) !void {
            try sleep(timeout);
        }

        fn start() !void {
            const childTimeout = std.time.ns_per_s;

            const begin = now();

            var task: SpawnHandle(tocancel) = undefined;
            try spawn(&task, .{childTimeout}, null);
            defer {
                task.join() catch |err| switch (err) {
                    error.TaskCancelled => {}, // we know
                    else => @panic("unexpected error"),
                };
            }

            // go async to trigger the child to run
            try sleep(0);

            // cancel the child
            task.cancel();

            // this test should run in << 1 sec
            try std.testing.expect(now() - begin < childTimeout);
        }
    }.start;

    try V.testing.runTest(alloc, V.DefaultTestConfig, init, .{});
}

test "basic cancellation" {
    try test_basic(vortex.Vortex);
}

// A cancellation torture test. Recursively spawns `fanout' number of tasks,
// up to a predefined `max_levels' recursion depth. Each task sleeps for
// a specified amount of time and then cancels a specified number of its
// spawned children. Used by cancel-fuzz to find scheduler issues, each
// of which is saved in the test driver below.
pub fn TortureTask(comptime V: type, comptime options: anytype) type {
    return TortureTaskImpl(V, 0, options.fanout, options.max_levels);
}

// Turn the recursive task spawning into a compile-time recursion problem
// by generating unique task entry points (exec) for each level of the
// task tree. This gets around the problem of the async Frame() depending
// on itself. By convention, level 0 is the root level.
fn TortureTaskImpl(
    comptime V: type,
    comptime level: comptime_int,
    comptime fanout: comptime_int,
    comptime max_levels: comptime_int,
) type {
    const Timespec = V.Timespec;
    const SpawnHandle = V.task.SpawnHandle;
    const spawn = V.task.spawn;
    const sleep = V.time.sleep;
    const emit = V.event.emit;

    const Events = RegisterEvents(V, if (builtin.is_test) .debug else .info);

    assert(level >= 0 and level < max_levels);

    return struct {
        // How many tasks do we need across all levels?
        pub const num_tasks = taskCount(max_levels, fanout);
        pub const time_scale = std.time.ns_per_us;

        // returns the number of tasks given 'L' levels and fanout 'N'
        fn taskCount(
            comptime L: comptime_int,
            comptime N: comptime_int,
        ) comptime_int {
            // The total number of tasks is defined by the geometric series:
            //    1 + N + N^2 + ... + N^(L-1) = (1 - N^L) / (1 - N)
            assert(L >= 0);
            assert(N >= 1);

            const pow = try std.math.powi(isize, N, L);
            return if (N == 1) L else @divExact(
                1 - pow,
                1 - N,
            );
        }

        pub fn exec(
            pidx: usize, // parent index (at its level, 0-based)
            sibling: usize, // sibling index (0-based)
            data: []const u8, // task-defining data (see below)
        ) anyerror!void {
            // which index within this level are we?
            const levIndex = pidx * fanout + sibling;

            // which index globally are we?
            const idx = taskCount(level, fanout) + levIndex;

            // extract the specifications for this task from `data'
            const td = struct { tocancel: usize, delay: Timespec }{
                .tocancel = std.math.min(data[idx], fanout),
                .delay = time_scale * @as(Timespec, data[idx + num_tasks]),
            };

            emit(
                Events.LevelStart,
                .{ .idx = idx, .lev = level, .del = td.delay },
            );

            if (level == max_levels - 1) {
                defer emit(Events.LevelReturn, .{ .idx = idx });
                if (td.delay > 0) try sleep(td.delay);
                return;
            }

            defer emit(Events.LevelReturn, .{ .idx = idx });

            const ChildTask = TortureTaskImpl(V, level + 1, fanout, max_levels);
            const Handle = SpawnHandle(ChildTask.exec);
            var tasks = [1]Handle{undefined} ** fanout;

            for (tasks) |*t, i| {
                spawn(t, .{ levIndex, i, data }, null) catch unreachable;
            }

            // Whenever we spawn a task (or tasks) we must guarantee that all
            // paths exiting this function 'join' the spawned task. Expect to
            // see a defer/errdefer after spawn every time, or else it's
            // probably a bug.
            defer {
                for (tasks) |*t| {
                    t.join() catch |err| switch (err) {
                        error.TaskCancelled => {}, // nothing to clean up
                        else => @panic("Unexpected error"),
                    };
                }
            }

            if (td.delay > 0) {
                try sleep(td.delay);
            }

            var i: usize = 0;
            while (i < td.tocancel) : (i += 1) {
                emit(Events.CancelSubtree, .{ .idx = idx, .sub = i });
                tasks[i].cancel();
            }
        }
    };
}

test "torture cancellation" {
    {
        const V = vortex.Vortex;
        const TT = TortureTask(vortex.Vortex, .{ .fanout = 2, .max_levels = 2 });
        const data = [1]u8{0} ** (TT.num_tasks * 2);
        try V.testing.runTest(
            alloc,
            V.DefaultTestConfig,
            TT.exec,
            .{ 0, 0, &data },
        );
    }

    // {
    //     // With an Autojump clock, the two child tasks end up with the same
    //     // absolute timeout and that triggered a hang due to how the timewheel
    //     // entries were deleted when >1 entry was in a slot.
    //     const TT = TortureTask(.{ .fanout = 2, .max_levels = 2 });
    //     const data = [_]u8{ 0, 0, 0, 0, 255, 255 };
    //     try vx.testing.runTest(
    //         alloc,
    //         vx.AutojumpTestConfig,
    //         TT.exec,
    //         .{ 0, 0, &data },
    //     );
    // }

    // {
    //     // Cancel a task that has already completed an async op, but hasn't
    //     // yet been rescheduled.
    //     const TT = TortureTask(.{ .fanout = 2, .max_levels = 2 });
    //     const data = [_]u8{ 1, 0, 0, 255, 255, 255 };
    //     try vx.testing.runTest(
    //         alloc,
    //         vx.AutojumpTestConfig,
    //         TT.exec,
    //         .{ 0, 0, &data },
    //     );
    // }
}

// Put the event registration behind a log-level generic function so we can vary
// based on whether this is used in a unit test or a standalone fuzz test.
// NOTE: this will probably break if/when we want to connect all event
// registries from some top-level root package. Revisit when we get there.
fn RegisterEvents(comptime V: type, log_level: std.log.Level) type {
    return struct {
        const ScopedRegistry = V.event.Registry("test.cncl", enum {
            level_start,
            level_return,
            cancel_subtree,
        });

        const LevelStart = ScopedRegistry.register(
            .level_start,
            log_level,
            struct { idx: usize, lev: usize, del: V.Timespec },
        );

        const LevelReturn = ScopedRegistry.register(
            .level_return,
            log_level,
            struct { idx: usize },
        );

        const CancelSubtree = ScopedRegistry.register(
            .cancel_subtree,
            log_level,
            struct { idx: usize, sub: usize },
        );
    };
}
