//! Demonstrates specifying arg ranges via helpers

const std = @import("std");
const metron = @import("metron");

const range = metron.range;
const State = metron.State;

pub fn main() anyerror!void {
    try metron.run(struct {
        pub const name = "bitset";
        pub const args = range(usize, 2, 8, 1024); // {8, 16, 32, ..., 1024}

        pub fn run(state: *State, n: usize) !void {
            var bs = try std.bit_set.DynamicBitSet.initFull(state.alloc, n);
            defer bs.deinit();

            bs.toggle(n / 2); // flip a bit

            var iter = state.iter();
            var res: usize = undefined;
            while (iter.next()) |i| {
                std.mem.doNotOptimizeAway(i);
                res = bs.count();
            }
            std.debug.assert(res == n - 1);
            std.mem.doNotOptimizeAway(res);
        }
    });
}
