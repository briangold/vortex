//! Demonstrates multi-threaded tests

const std = @import("std");
const metron = @import("metron");

const RateCounter = metron.RateCounter;
const State = metron.State;

// global: shared counter accessible by all threads
var counter: std.atomic.Atomic(usize) = undefined;

pub fn main() anyerror!void {
    try metron.run(struct {
        pub const name = "threads";
        pub const threads = [_]usize{ 1, 2, 4, 8 };

        pub const Counters = struct {
            rate: RateCounter("add", .div_1000) = .{},
        };

        pub fn uncoord(state: *State) Counters {
            // Just an empty work loop that counts up locally on each thread,
            // useful to see how time is reported using wall-clock time on the
            // main thread, recording the duration from the point the main
            // thread enters a barrier in start.iter() to exiting another
            // barrier in the final work-loop iteration.
            var iter = state.iter();
            while (iter.next()) |i| {
                std.mem.doNotOptimizeAway(i);
            }

            // return the per-thread count
            return Counters{ .rate = .{ .val = state.iterations } };
        }

        pub fn fetchAdd(state: *State) Counters {
            if (state.thread_id == 0) {
                counter.store(0, .Release);
            }

            // A barrier inside state.iter() synchronizes all threads as they
            // enter the work loop. All threads will see the initialization
            // performed by thread 0 above.

            var iter = state.iter();
            while (iter.next()) |_| {
                _ = counter.fetchAdd(1, .AcqRel);
            }

            // A barrier inside iter.next() synchronizes all threads as they
            // exit the work loop. We can expect the count to be ready to
            // check at this point.

            if (state.thread_id == 0) {
                const c = counter.load(.Acquire);
                std.debug.assert(c == state.threads * state.iterations);
            }

            // return the per-thread count
            return Counters{ .rate = .{ .val = state.iterations } };
        }

        pub fn localAdd(state: *State) Counters {
            if (state.thread_id == 0) {
                counter.store(0, .Release);
            }

            // A barrier inside state.iter() synchronizes all threads as they
            // enter the work loop. All threads will see the initialization
            // performed by thread 0 above.

            var iter = state.iter();
            while (iter.next()) |i| {
                if (i + 1 == state.iterations) {
                    _ = counter.fetchAdd(i + 1, .AcqRel);
                }
            }

            // A barrier inside iter.next() synchronizes all threads as they
            // exit the work loop. We can expect the count to be ready to
            // check at this point.

            if (state.thread_id == 0) {
                const c = counter.load(.Acquire);
                std.debug.assert(c == state.threads * state.iterations);
            }

            // return the per-thread count
            return Counters{ .rate = .{ .val = state.iterations } };
        }
    });
}
