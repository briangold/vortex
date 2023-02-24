//! Metron is a microbenchmarking library for Zig, modeled after the Google
//! Benchmark library for C/C++. See README.md for details and tour/README.md
//! for a feature guide.
const std = @import("std");

pub const Runner = @import("src/Runner.zig");
pub const Options = Runner.Options;

pub const State = @import("src/State.zig");

const spec = @import("src/spec.zig");

// helpers re-exported for use by clients
// TODO: re-organize these into an API we can export as a whole?

pub const range = spec.range;
pub const denseRange = spec.denseRange;
pub const argsProduct = spec.argsProduct;
pub const RateCounter = spec.RateCounter;
pub const ByteCounter = spec.ByteCounter;

/// Runs a benchmark Spec using a default allocator and default Options
pub fn run(comptime Spec: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (@import("builtin").mode == .Debug) {
        std.debug.assert(!gpa.deinit());
    };

    var r = Runner.init(gpa.allocator(), .{});
    try r.run(Spec);
}

test "metron" {
    _ = std.testing.refAllDecls(@This());
}
