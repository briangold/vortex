const std = @import("std");

const Timer = std.time.Timer;

const Barrier = @import("Barrier.zig");

const State = @This();

iterations: usize,
duration: ?u64 = null,
thread_id: usize,
threads: usize,
bytes: ?usize = null,
barrier: *Barrier,
alloc: std.mem.Allocator, // TODO: use a tracked allocator so we can report stats
timer: Timer = undefined,

pub fn startTimer(state: *State) void {
    @setCold(true);
    state.timer = Timer.start() catch unreachable;
    state.barrier.wait();
}

pub fn stopTimer(state: *State) void {
    @setCold(true);
    state.barrier.wait();
    state.duration = state.timer.read();
}

pub fn iter(state: *State) Iterator {
    var it = Iterator{
        .cur = state.iterations,
        .state = state,
    };

    state.startTimer();

    return it;
}

pub const Iterator = struct {
    // keep iterator to minimum so the compiler has a better chance of putting
    // cur in register and avoid ld/st to the stack
    cur: usize,
    state: *State,

    pub inline fn next(it: *Iterator) ?usize {
        if (it.cur != 0) {
            it.cur -= 1;
            return it.cur;
        }

        it.state.stopTimer();
        return null;
    }
};
