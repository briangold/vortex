//! Measures memory-system performance, including CPU caches.

const std = @import("std");
const metron = @import("metron");

const State = metron.State;

pub fn main() anyerror!void {
    try metron.run(struct {
        pub const name = "mem";
        pub const args = metron.range(usize, 8, 1 << 10, 1 << 28);
        pub const arg_units = .div_1024;
        pub const min_iter = 100;

        pub const Counters = struct {
            rate: metron.ByteCounter(.div_1024) = .{},
        };

        const cache_line = std.atomic.cache_line;

        pub fn seq(state: *State, bytes: usize) !Counters {
            const count = bytes / @sizeOf(usize);
            var arr = try state.alloc.alignedAlloc(usize, cache_line, count);
            defer state.alloc.free(arr);

            var prng = std.rand.DefaultPrng.init(0);
            const random = prng.random();

            for (arr) |*x| {
                x.* = random.uintLessThan(usize, count);
            }

            var acc: usize = 0;
            var iter = state.iter();
            while (iter.next()) |_| {
                // Vectorizing this loop ensures we are not bottlenecked on
                // the arithmetic in each loop iteration, which the compiler
                // isn't even unrolling. NOTE that this code only works for
                // counts that are multiples of the vector size (vsz).
                const vsz = 8;
                var i: usize = 0;
                while (i < count) : (i += vsz) {
                    var vec: @Vector(vsz, usize) = arr[i..][0..vsz].*;
                    acc = acc +% @reduce(.Add, vec);
                }
            }
            std.mem.doNotOptimizeAway(acc);

            return Counters{ .rate = .{ .val = bytes * state.iterations } };
        }

        pub fn rand(state: *State, bytes: usize) !Counters {
            const count = bytes / @sizeOf(usize);
            var arr = try state.alloc.alignedAlloc(usize, cache_line, count);
            defer state.alloc.free(arr);

            var prng = std.rand.DefaultPrng.init(0);
            const random = prng.random();

            for (arr) |*x| {
                x.* = random.uintLessThan(usize, count);
            }

            var acc: usize = 0;
            var iter = state.iter();
            while (iter.next()) |_| {
                const vsz = 8;

                var vec: @Vector(vsz, usize) = undefined;
                var loc: @Vector(vsz, usize) = undefined;

                comptime var vi: usize = 0;
                inline while (vi < vsz) : (vi += 1) loc[vi] = vi;

                var i: usize = 0;
                while (i < count) : (i += vsz) {
                    // Read from locations as we go
                    //  NOTE - this would be a place for a @gather() intrinsic
                    //  See: https://github.com/ziglang/zig/issues/903
                    vi = 0;
                    inline while (vi < vsz) : (vi += 1) {
                        vec[vi] = arr[loc[vi]];
                    }

                    // Update locations - each vector lane is independently
                    // providing a chain of offsets that bounce through the
                    // array at random. By initializing arr with random values
                    // in the range [0, count) we can just reuse those as our
                    // "next" locations.
                    loc = vec;

                    // compute sum
                    acc = acc +% @reduce(.Add, vec);
                }
            }
            std.mem.doNotOptimizeAway(acc);

            return Counters{ .rate = .{ .val = bytes * state.iterations } };
        }
    });
}
