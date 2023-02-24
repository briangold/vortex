//! Tests of memory hierarchy

const std = @import("std");
const metron = @import("metron");

const range = metron.range;
const ByteCounter = metron.ByteCounter;
const State = metron.State;

pub fn main() anyerror!void {
    try metron.run(struct {
        pub const name = "cache";
        pub const args = range(usize, 2, 1 << 13, 1 << 26);
        pub const arg_units = .div_1024;

        pub const Counters = struct {
            rate: ByteCounter(.div_1024) = .{},
        };

        // source: Chandler Carruth's CppCon 2017 talk
        // https://www.youtube.com/watch?v=2EWejmkKlxs
        pub fn do_bench(state: *State, bytes: usize) !Counters {
            const count = bytes / @sizeOf(usize) / 2; // half for indices, half for data
            const List = std.ArrayListAligned(usize, std.atomic.cache_line);

            var prng = std.rand.DefaultPrng.init(0);
            const random = prng.random();

            var data = try List.initCapacity(state.alloc, count);
            defer data.deinit();

            var indx = try List.initCapacity(state.alloc, count);
            defer indx.deinit();

            data.expandToCapacity();
            for (data.items) |*d| {
                // generate a random usize [0, max(usize)]
                d.* = random.int(usize);
            }

            indx.expandToCapacity();
            for (indx.items) |*i| {
                // generate a random index into data [0, count)
                i.* = random.uintLessThan(usize, count);
            }

            var iter = state.iter();
            while (iter.next()) |_| {
                var sum: usize = 0;
                for (indx.items) |i| {
                    sum = sum +% data.items[i];
                }
                std.mem.doNotOptimizeAway(sum);
            }

            return Counters{ .rate = .{ .val = bytes * state.iterations } };
        }
    });
}
