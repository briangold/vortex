//! A few different ways to compute the length of a Fibonacci sequence

const std = @import("std");
const metron = @import("metron");

const State = metron.State;

pub fn main() anyerror!void {
    try metron.run(struct {
        pub const name = "fib";
        pub const args = [_]usize{ 1, 2, 5, 10, 20 };

        pub fn recurse(state: *State, n: usize) void {
            var iter = state.iter();
            var res: usize = undefined;
            while (iter.next()) |i| {
                // ensure the compiler doesn't hoist fib_recursive out of the
                // loop, as it observes it has no side effects
                std.mem.doNotOptimizeAway(i);
                res = fib_recursive(n);
            }
            // ensure res isn't thrown away entirely
            std.mem.doNotOptimizeAway(res);
        }

        pub fn sequential(state: *State, n: usize) void {
            var iter = state.iter();
            var res: usize = undefined;
            while (iter.next()) |i| {
                // ensure the compiler doesn't hoist fib_sequential out of the
                // loop, as it observes it has no side effects
                std.mem.doNotOptimizeAway(i);
                res = fib_sequential(n);
            }
            // ensure res isn't thrown away entirely
            std.mem.doNotOptimizeAway(res);
        }
    });
}

fn fib_recursive(n: usize) usize {
    if (n < 2) return n;
    return fib_recursive(n - 1) + fib_recursive(n - 2);
}

fn fib_sequential(n: usize) usize {
    if (n < 2) return n;

    var i_2: usize = 0;
    var i_1: usize = 1;
    var idx: usize = 2;
    while (idx < n) : (idx += 1) {
        const tmp = i_1;
        i_1 = i_1 + i_2;
        i_2 = tmp;
    }

    return i_2 + i_1;
}

test "fib correctness" {
    const exp = [_]usize{ 0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144 };

    for (exp) |e, i| {
        try std.testing.expectEqual(e, fib_sequential(i));
        try std.testing.expectEqual(e, fib_recursive(i));
    }
}
