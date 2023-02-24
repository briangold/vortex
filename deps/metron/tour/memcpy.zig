//! Demonstrates specifying arg units and byte-count results for reporting

const std = @import("std");
const metron = @import("metron");

const range = metron.range;
const ByteCounter = metron.ByteCounter;
const State = metron.State;

pub fn main() anyerror!void {
    try metron.run(struct {
        pub const name = "memcpy";
        pub const args = range(usize, 4, 1 << 10, 1 << 26);
        pub const arg_units = .div_1024;

        pub const Counters = struct {
            rate: ByteCounter(.div_1024) = .{},
        };

        pub fn run(state: *State, n: usize) !Counters {
            const cl = std.atomic.cache_line;

            var src = try state.alloc.alignedAlloc(u8, cl, n);
            defer state.alloc.free(src);
            var dst = try state.alloc.alignedAlloc(u8, cl, n);
            defer state.alloc.free(dst);

            std.mem.set(@TypeOf(src[0]), src, 'x');

            var iter = state.iter();
            var res: usize = undefined;
            while (iter.next()) |_| {
                std.mem.copy(@TypeOf(src[0]), dst, src);
            }
            std.mem.doNotOptimizeAway(res);

            // tell the runner we've processed this many bytes (for reporting)
            return Counters{
                .rate = .{ .val = n * state.iterations },
            };
        }
    });
}
