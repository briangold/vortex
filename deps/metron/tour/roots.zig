//! Demonstrates compound arguments via cartesian-product helper

const std = @import("std");
const metron = @import("metron");

const argsProduct = metron.argsProduct;
const State = metron.State;

pub fn main() anyerror!void {
    try metron.run(struct {
        pub const name = "roots";
        pub const args = argsProduct(.{
            .n = [_]usize{ 1, 2, 5, 8 }, // polynomial degree
            .a = [_]f64{ 1.1, 11.0 }, // root to find
        });
        pub const arg_names = [_][]const u8{ "n", "a" };

        pub fn run(state: *State, arg: @TypeOf(args[0])) void {
            const x0 = 1.0; // starting guess
            const eps = 0.01; // accuracy
            const nf = @intToFloat(f64, arg.n);

            var iter = state.iter();
            while (iter.next()) |i| {
                std.mem.doNotOptimizeAway(i);
                const res = RootFinder.find_root(x0, nf, arg.a, eps);
                std.mem.doNotOptimizeAway(res);
            }
        }
    });
}

const RootFinder = struct {
    fn find_root(x0: f64, d: f64, a: f64, eps: f64) f64 {
        var x = x0;
        while (@fabs(x - a) >= eps) {
            x -= fx(x, d, a) / fprime(x, d, a);
        }
        return x;
    }

    inline fn fx(x: f64, d: f64, a: f64) f64 {
        return std.math.pow(f64, x - a, d);
    }

    inline fn fprime(x: f64, d: f64, a: f64) f64 {
        return d * std.math.pow(f64, x - a, d - 1.0);
    }
};

test "roots" {
    const start = 1.0;
    const eps = 0.01;
    const degree = [_]f64{ 1, 2, 5, 8 };
    const root = [_]f64{ 1.1, 11.0 };
    for (root) |r| {
        for (degree) |d| {
            try std.testing.expectApproxEqAbs(
                r,
                RootFinder.find_root(start, d, r, eps),
                eps,
            );
        }
    }
}
