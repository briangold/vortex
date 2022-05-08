//!
//! Fuzz testing cancellation in the scheduler. This file is a WIP but 
//! exposed a number of tricky bugs in the scheduler design.
//!
//! To run a fuzzing campaign:
//!
//!   zig build cancel-fuzz  # see build.zig for more info
//!   mkdir input  # only need this once
//!   # change '80' in dd count to be 2 * num_tasks
//!   dd if=/dev/zero of=input/test.in count=80 bs=1
//!   afl-fuzz -i input -o output -t 5000 -- ./zig-out/bin/cancel-fuzz
//!   
//! To debug a specific crash:
//!
//!   ./zig-out/bin/cancel-debug < output/default/crash/id\:000000.......
//!
//! Future work:
//!   - guard against trying to build on Darwin?
//!   - add unit tests for every crash/hang 
//!   - improve ergonomics around variations (autojump, diff options for sizes)
//!
const std = @import("std");
const assert = std.debug.assert;

const vx = @import("vortex");

fn cMain() callconv(.C) void {
    main() catch unreachable;
}

comptime {
    @export(cMain, .{ .name = "main", .linkage = .Strong });
}

// The core test logic is in the separate cancel test suite
const TortureTask = @import("cancel.zig").TortureTask;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == false);

    const alloc = gpa.allocator();

    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(data);

    const TT = TortureTask(.{ .fanout = 3, .max_levels = 4 });
    if (data.len != 2 * TT.num_tasks) return;

    try vx.testing.runTest(
        alloc,
        vx.SingleThreadAutojumpTestConfig,
        TT.exec,
        .{ 0, 0, data },
    );
}
