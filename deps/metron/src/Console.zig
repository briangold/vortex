const std = @import("std");
const builtin = @import("builtin");

const Decl = std.builtin.TypeInfo.Declaration;

const Context = @import("Context.zig");
const spec = @import("spec.zig");

const Console = @This();

name_width: usize,

pub fn init(
    writer: anytype,
    comptime Spec: anytype,
    context: Context,
) !Console {
    _ = context;

    if (builtin.is_test) {
        try writer.writeAll("\n");
    }

    var console = Console{
        .name_width = calcNameWidth(Spec),
    };

    try console.printHeader(writer);

    return console;
}

pub fn report(
    console: Console,
    writer: anytype,
    comptime B: type,
    comptime defname: ?[]const u8,
    comptime arg: anytype,
    comptime threads: ?usize,
    results: anytype,
) !void {
    var cw = std.io.countingWriter(writer);
    try spec.printTestName(cw.writer(), B, defname, arg, threads);

    // pad the full test name to name_width
    while (cw.bytes_written < console.name_width) {
        _ = try cw.write(" ");
    }

    std.debug.assert(results.len == 1);

    const ns_per_iter = @intToFloat(f64, results[0].ns) / @intToFloat(f64, results[0].ops);
    if (ns_per_iter < 1.0) {
        try writer.print("{d:10.3}", .{ns_per_iter});
    } else if (ns_per_iter < 10.0) {
        try writer.print("{d:10.2}", .{ns_per_iter});
    } else if (ns_per_iter < 100.0) {
        try writer.print("{d:10.1}", .{ns_per_iter});
    } else {
        try writer.print("{d:10.0}", .{ns_per_iter});
    }

    try writer.print(" ns   {d:12}", .{results[0].ops});

    const fields = spec.CounterFields(B);
    inline for (fields) |f| {
        const ctr = @field(results[0].counters, f.name);
        const C = @TypeOf(ctr);
        const unit_scale: spec.UnitDisplay = C.unit_scale;

        const pfx = [_][]const u8{ "", "K", "M", "G", "T", "P" };
        const div = @intToFloat(f64, @enumToInt(unit_scale));
        const units = if (div == 1024) "i" ++ C.unit_name else C.unit_name;

        if (C.display != .rate) @compileError("non-rate counters not implemented");
        const sfx = "/s";

        const per_ns = @intToFloat(f64, ctr.val) / @intToFloat(f64, results[0].ns);
        const per_s = per_ns * @intToFloat(f64, std.time.ns_per_s);
        var val = per_s;
        for (pfx) |p| {
            if (val < div) {
                try writer.print(
                    " {s}={d:.3}{s}{s}{s}",
                    .{ f.name, val, p, units, sfx },
                );
                break;
            }
            val /= div;
        }
    }

    try writer.writeAll("\n");
}

fn printHeaderBar(console: Console, writer: anytype) !void {
    const bar_len = console.name_width + 28;
    var i = bar_len;
    while (i > 0) : (i -= 1) {
        try writer.writeAll("-");
    }
    try writer.writeAll("\n");
}

fn printHeader(console: Console, writer: anytype) !void {
    try console.printHeaderBar(writer);

    var cw = std.io.countingWriter(writer);
    try cw.writer().writeAll("Benchmark");
    while (cw.bytes_written < console.name_width) {
        _ = try cw.write(" ");
    }

    try writer.print("{s:13} {s:14}\n", .{ "Time", "Iterations" });

    try console.printHeaderBar(writer);
}

fn calcNameWidth(comptime Spec: anytype) usize {
    if (comptime spec.specLength(Spec) > 1) {
        // Spec is a list of benchmarks... compute max across each
        var max: usize = 0;
        inline for (Spec) |B| {
            max = @maximum(max, calcNameWidth(B));
        }
        return max;
    }

    // Spec is a single benchmark, compute max over all its test cases

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var max: usize = 10; // min

    const threads = comptime if (@hasDecl(Spec, "threads"))
        Spec.threads
    else
        [_]?usize{null};

    const args = comptime if (@hasDecl(Spec, "args"))
        Spec.args
    else
        [_]void{{}};

    const funlist = comptime spec.functions(Spec);

    inline for (funlist) |fun| {
        inline for (args) |arg| {
            inline for (threads) |tc| {
                fbs.reset();

                spec.printTestName(
                    fbs.writer(),
                    Spec,
                    if (funlist.len > 1) fun.name else null,
                    arg,
                    tc,
                ) catch unreachable;

                max = @maximum(max, fbs.getPos() catch unreachable);
            }
        }
    }

    return max + 1; // add space
}

test "name width" {
    const TestSingleSpec = struct {
        pub const name = "short";
        pub const args = [_]usize{1};
        pub fn dummy() void {}
    };

    // minimum size
    try std.testing.expectEqual(@as(usize, 11), calcNameWidth(TestSingleSpec));

    const TestNamedSpec = struct {
        pub const name = "withNames";
        pub const args = [_]usize{1};
        pub const arg_names = [_][]const u8{"x"};
        pub fn dummy() void {}
    };

    try std.testing.expectEqual(@as(usize, 14), calcNameWidth(TestNamedSpec));

    const TestThreadsSpec = struct {
        pub const name = "foo";
        pub const args = [_]usize{1};
        pub const threads = [_]usize{ 1, 2, 8 };
        pub fn dummy() void {}
    };

    try std.testing.expectEqual(@as(usize, 16), calcNameWidth(TestThreadsSpec));

    const TestMultiSpec = .{
        struct {
            pub const name = "foo";
            pub const args = [_]usize{1};
            pub fn dummy() void {}
        },

        struct {
            pub const name = "aVeryLongNameForNoReason";
            pub const args = [_]usize{1};
            pub fn dummy() void {}
        },
    };

    try std.testing.expectEqual(@as(usize, 27), calcNameWidth(TestMultiSpec));

    // TODO: add more tests for compound/struct args and multiple pub fn's
}
