const std = @import("std");
const metron = @import("metron");
const vx = @import("vortex").Vortex;

const State = metron.State;

pub fn main() !void {
    const InitTask = struct {
        bench_state: *State,
        alloc: std.mem.Allocator,
        num_tasks: usize = 1,

        fn subtask(sleep_count: usize) !void {
            var i = sleep_count;
            while (i != 0) : (i -= 1) {
                try vx.time.sleep(0);
            }
        }

        fn start(self: *@This()) !void {
            const Handle = vx.task.SpawnHandle(subtask);
            var tasks = try self.alloc.alloc(Handle, self.num_tasks);
            defer self.alloc.free(tasks);

            // TODO: re-compute iterations below by multiplying?
            const sleep_count = self.bench_state.iterations / self.num_tasks;

            for (tasks) |*t| try vx.task.spawn(t, .{sleep_count}, null);
            // TODO: barrier

            self.bench_state.startTimer();

            for (tasks) |*t| try t.join();

            self.bench_state.stopTimer();
        }
    };

    try metron.run(struct {
        pub const name = "sleeper";

        // TODO: clean-up, for now we're manually adjusting these to use perf
        // and profile where time is spent.
        // pub const args = [_]usize{ 1, 2, 3, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };
        pub const args = [_]usize{1};
        pub const min_iter = 100_000_000;
        pub const arg_names = [_][]const u8{"num_tasks"};

        pub fn sleeper(state: *State, num_tasks: usize) void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer if (@import("builtin").mode == .Debug) {
                std.debug.assert(!gpa.deinit());
            };

            const alloc = gpa.allocator();

            vx.init(alloc, vx.DefaultTestConfig) catch |err|
                std.debug.panic("Unable to init Vortex engine: {}", .{err});

            defer vx.deinit(alloc);

            var task = InitTask{
                .bench_state = state,
                .alloc = alloc,
                .num_tasks = num_tasks,
            };
            vx.run(InitTask.start, .{&task}) catch |err|
                std.debug.panic("Error running task: {}", .{err});
        }
    });
}
