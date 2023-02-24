//! Measures the overhead in various forms of function calls.

const std = @import("std");
const metron = @import("metron");

const State = metron.State;

pub fn main() anyerror!void {
    try metron.run(struct {
        pub const name = "fn";
        pub const min_iter = 1000;

        pub fn inline_fn(state: *State) void {
            addDirect(.always_inline, state);
        }

        pub fn noinline_fn(state: *State) void {
            addDirect(.never_inline, state);
        }

        fn addDirect(modifier: anytype, state: *State) void {
            var iter = state.iter();
            var acc: usize = 0;
            while (iter.next()) |i| {
                std.mem.doNotOptimizeAway(i);
                acc = @call(.{ .modifier = modifier }, do_add, .{ acc, 1 });
            }
            std.mem.doNotOptimizeAway(acc);
        }

        fn do_add(x: usize, y: usize) usize {
            return x + y;
        }

        // Using @fieldParentPtr to implement the interface, each instance
        // has its own vtable and the compiler cannot guarantee that the
        // function pointer isn't changed somewhere. So it cannot de-virtualize
        // the call and pays for an indirect branch and function call overhead.
        pub fn fieldParentPtr(state: *State) void {
            var adder = FppAddConstant{ .val = 17 };
            addWithInterface(state, adder.interface());
        }

        // With a fat-pointer model, each object of a given concrete type shares
        // a common, static vtable. This enables the compiler to perform the
        // necessary analysis to de-virtualize the call, and the resulting
        // code is equivalent to the inline_fn variant above.
        pub fn fatPointer(state: *State) void {
            var adder = FatAddConstant{ .val = 17 };
            addWithInterface(state, adder.interface());
        }

        fn addWithInterface(state: *State, iface: anytype) void {
            var acc: usize = 0;
            var iter = state.iter();
            while (iter.next()) |i| {
                std.mem.doNotOptimizeAway(i);
                acc = iface.op(acc);
            }
            std.mem.doNotOptimizeAway(acc);
        }
    });
}

const FppAddConstant = struct {
    val: usize,
    vtable: FppUnaryOp = .{
        .opFn = op,
    },

    fn op(ptr: *FppUnaryOp, x: usize) usize {
        const adder = @fieldParentPtr(FppAddConstant, "vtable", ptr);
        return x + adder.val;
    }

    fn interface(adder: *FppAddConstant) *FppUnaryOp {
        return &adder.vtable;
    }
};

const FppUnaryOp = struct {
    opFn: *const fn (*FppUnaryOp, usize) usize,

    inline fn op(g: *FppUnaryOp, x: usize) usize {
        return g.opFn(g, x);
    }
};

const FatAddConstant = struct {
    val: usize,

    fn interface(self: *FatAddConstant) FatUnary {
        return FatUnary.init(self, op);
    }

    fn op(self: *FatAddConstant, x: usize) usize {
        return x + self.val;
    }
};

const FatUnary = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        op: *const fn (ptr: *anyopaque, x: usize) usize,
    };

    inline fn op(self: FatUnary, x: usize) usize {
        return self.vtable.op(self.ptr, x);
    }

    fn init(
        pointer: anytype,
        comptime opFn: fn (ptr: @TypeOf(pointer), x: usize) usize,
    ) FatUnary {
        const Ptr = @TypeOf(pointer);
        const ptr_info = @typeInfo(Ptr);

        const gen = struct {
            fn opImpl(ptr: *anyopaque, x: usize) usize {
                const self = @ptrCast(Ptr, @alignCast(ptr_info.Pointer.alignment, ptr));
                return @call(.{ .modifier = .always_inline }, opFn, .{ self, x });
            }

            const vtable = VTable{
                .op = opImpl,
            };
        };

        return .{
            .ptr = pointer,
            .vtable = &gen.vtable,
        };
    }
};

test "interfaces" {
    var fpp_adder = FppAddConstant{ .val = 17 };
    try std.testing.expectEqual(@as(usize, 19), fpp_adder.interface().op(2));

    var fat_adder = FatAddConstant{ .val = 17 };
    try std.testing.expectEqual(@as(usize, 19), fat_adder.interface().op(2));
}
