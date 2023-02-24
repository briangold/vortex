//! Tools for working with benchmark specifications. Specs are expressed as
//! types with a required signature. The functions in this module operate on
//! these types to validate conformance, derive traits, etc.

const std = @import("std");

const Decl = std.builtin.TypeInfo.Declaration;

// Terminology guiding the naming of things:
//  - A Spec is the generic name for one or more Benchmark definitions
//  - A Benchmark repesents the execution of a function parametrized over its
//    arguments and thread counts
//  - A Test is a specific (function, arg set, #threads) combination

/// Validates the given specification, either returning nothing (success) or
/// raising a compile error.
fn validate(comptime Spec: anytype) void {
    if (@TypeOf(Spec) == type) {
        const info = @typeInfo(Spec);
        if (info != .Struct) @compileError("Expected struct type");

        // TODO: ensure properties of Spec
    } else {
        const info = @typeInfo(@TypeOf(Spec));
        if (info != .Struct) @compileError("Expected struct type");
        if (!info.Struct.is_tuple) @compileError("Expected tuple");

        inline for (Spec) |B| {
            validate(B);
        }
    }
}

pub const UnitDisplay = enum(usize) {
    raw = std.math.maxInt(usize),
    div_1000 = 1000,
    div_1024 = 1024,
};

pub fn RateCounter(
    comptime name: []const u8,
    comptime scale: UnitDisplay,
) type {
    return struct {
        pub const display = .rate;
        pub const unit_name = name;
        pub const unit_scale = scale;

        val: usize = 0,
    };
}

pub fn ByteCounter(scale: UnitDisplay) type {
    return RateCounter("B", scale);
}

pub fn functions(comptime Benchmark: type) []const Decl {
    var res: []const Decl = &[_]Decl{};
    for (std.meta.declarations(Benchmark)) |decl| {
        if (!decl.is_pub) continue;
        if (@typeInfo(@TypeOf(@field(Benchmark, decl.name))) != .Fn) continue;

        res = res ++ [_]Decl{decl};
    }
    return res;
}

pub fn CounterFields(comptime Benchmark: type) []const std.builtin.Type.StructField {
    if (@hasDecl(Benchmark, "Counters")) {
        return std.meta.fields(Benchmark.Counters);
    }

    return &[_]std.builtin.Type.StructField{};
}

/// Writes a specific test name to a given io.Writer
pub fn printTestName(
    w: anytype,
    comptime Benchmark: anytype,
    comptime maybe_fun_name: ?[]const u8,
    comptime arg: anytype,
    comptime maybe_threads: ?usize,
) !void {
    try w.print("{s}", .{Benchmark.name});

    if (maybe_fun_name) |fun_name| {
        try w.print("/{s}", .{fun_name});
    }

    const arg_names = comptime if (@hasDecl(Benchmark, "arg_names"))
        Benchmark.arg_names
    else
        &[_]?[]const u8{null};

    // TODO: make arg_units a slice to have per-arg customization?
    const arg_units = comptime if (@hasDecl(Benchmark, "arg_units"))
        Benchmark.arg_units
    else
        UnitDisplay.raw;

    switch (@typeInfo(@TypeOf(arg))) {
        .Int, .Float, .Enum => {
            try printScalarArg(w, arg, arg_names[0], arg_units);
        },

        .Struct => {
            const fields = std.meta.fields(@TypeOf(arg));
            inline for (fields) |fld, i| {
                const val = @field(arg, fld.name);
                const name = if (i < arg_names.len) arg_names[i] else null;
                try printScalarArg(w, val, name, arg_units);
            }
        },

        .Void => {},

        else => @compileError("Unhandled arg type: " ++ @typeName(@TypeOf(arg))),
    }

    if (maybe_threads) |threads| {
        try w.print("/threads:{d}", .{threads});
    }
}

fn printScalarArg(
    w: anytype,
    comptime arg: anytype,
    comptime maybe_name: ?[]const u8,
    comptime unit_display: UnitDisplay,
) !void {
    try w.writeAll("/");

    if (maybe_name) |name| {
        try w.print("{s}:", .{name});
    }

    switch (@typeInfo(@TypeOf(arg))) {
        .Enum => try w.writeAll(@tagName(arg)),
        .Int => try printIntNormalized(w, arg, unit_display),
        .Float => try w.print("{d}", .{arg}),
        // add other specializations as needed
        else => try w.print("{}", .{arg}),
    }
}

fn printIntNormalized(
    w: anytype,
    comptime arg: anytype,
    comptime unit_display: UnitDisplay,
) !void {
    if (unit_display == .raw) return w.print("{d}", .{arg});

    const div: f64 = switch (unit_display) {
        .raw => unreachable, // already returned
        .div_1000 => 1000,
        .div_1024 => 1024,
    };

    const units = [_][]const u8{ "", "k", "M", "G", "T", "P", "E" };
    var val = @intToFloat(f64, arg);
    for (units) |u| {
        if (val < div) {
            return w.print("{d}{s}", .{ val, u });
        }

        val /= div;
    }
}

/// How many benchmarks does this Spec define?
pub fn specLength(comptime Spec: anytype) usize {
    comptime validate(Spec); // ensure we have a valid specification

    return switch (@TypeOf(Spec)) {
        type => 1,
        else => std.meta.fields(@TypeOf(Spec)).len,
    };
}

pub fn range(
    comptime T: type,
    comptime mult: T,
    comptime low: T,
    comptime high: T,
) [rangeSize(mult, low, high)]T {
    const N = rangeSize(mult, low, high);
    var res: [N]T = undefined;

    var i: usize = 0;
    var val = low;
    while (val <= high) : (val *= mult) {
        res[i] = val;
        i += 1;
    }

    return res;
}

fn rangeSize(
    comptime mult: anytype,
    comptime low: @TypeOf(mult),
    comptime high: @TypeOf(mult),
) usize {
    var i: usize = 0;
    var val = low;
    while (val <= high) : (val *= mult) {
        i += 1;
    }
    return i;
}

test "range" {
    try std.testing.expectEqual(@as(usize, 1), comptime rangeSize(2, 2, 2));
    try std.testing.expectEqual(@as(usize, 2), comptime rangeSize(2, 1, 2));
    try std.testing.expectEqual(@as(usize, 3), comptime rangeSize(3, 3, 27));

    const r1 = comptime range(usize, 2, 1, 8);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 2, 4, 8 }, &r1);

    const r2 = comptime range(usize, 3, 4, 36);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 4, 12, 36 }, &r2);
}

pub fn denseRange(
    comptime T: type,
    comptime low: T,
    comptime high: T,
) [high - low + 1]T {
    const N = high - low + 1;
    var res: [N]T = undefined;

    var val = low;
    while (val <= high) : (val += 1) {
        res[val - low] = val;
    }

    return res;
}

test "denseRange" {
    const r1 = comptime denseRange(usize, 13, 17);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 13, 14, 15, 16, 17 }, &r1);
}

/// Form the struct type for the slice returned by argsProduct. Takes a struct-
/// of-slices and returns the struct type formed by combining elements from
/// each slice.
pub fn Args(comptime def: anytype) type {
    const info = @typeInfo(@TypeOf(def));
    if (info != .Struct) @compileError("Expected struct type");

    const fields = std.meta.fields(@TypeOf(def));

    var tuple_fields: [fields.len]std.builtin.Type.StructField = undefined;
    inline for (fields) |f, i| {
        const slice = @field(def, f.name);
        const T = @TypeOf(slice[0]);

        tuple_fields[i] = .{
            .name = f.name,
            .field_type = T,
            .default_value = null,
            .is_comptime = false,
            .alignment = if (@sizeOf(T) > 0) @alignOf(T) else 0,
        };
    }

    return @Type(.{
        .Struct = .{
            .is_tuple = false,
            .layout = .Auto,
            .decls = &.{},
            .fields = &tuple_fields,
        },
    });
}

/// Returns the combinations (cartesian product) of a struct-of-slices. The
/// result will be a slice-of-structs, where each slice element is an argument
/// combination for the function being tested.
/// NOTE: must be called from comptime context
pub fn argsProduct(comptime def: anytype) [argsProductCount(def)]Args(def) {
    const fields = std.meta.fields(@TypeOf(def));

    const N = argsProductCount(def);
    var res: [N]Args(def) = undefined;

    var n: usize = 0;
    while (n < N) : (n += 1) {
        var q: usize = n;
        var r: usize = 0;

        comptime var i = @as(comptime_int, fields.len - 1);
        inline while (i >= 0) : (i -= 1) {
            var arglist = @field(def, fields[i].name);
            r = q % arglist.len;
            q = q / arglist.len;

            @field(res[n], fields[i].name) = arglist[r];
        }
    }

    return res;
}

fn argsProductCount(comptime def: anytype) comptime_int {
    const fields = std.meta.fields(@TypeOf(def));

    var count: usize = 1;
    inline for (fields) |f| {
        count *= @field(def, f.name).len;
    }

    return count;
}

test "args" {
    const a1 = .{
        .n = [_]usize{ 1, 5, 10 },
        .v = [_]bool{ false, true },
    };
    const A1 = Args(a1);

    const a1_fields = std.meta.fields(A1);
    try std.testing.expectEqual(@as(usize, 2), a1_fields.len);
    try std.testing.expectEqualSlices(u8, "n", a1_fields[0].name);
    try std.testing.expectEqualSlices(u8, "v", a1_fields[1].name);
    try std.testing.expect(a1_fields[0].field_type == usize);
    try std.testing.expect(a1_fields[1].field_type == bool);

    const p1 = argsProduct(a1);

    try std.testing.expectEqual(@as(usize, 6), p1.len);

    const exp = &[_]Args(a1){
        .{ .n = 1, .v = false },
        .{ .n = 1, .v = true },
        .{ .n = 5, .v = false },
        .{ .n = 5, .v = true },
        .{ .n = 10, .v = false },
        .{ .n = 10, .v = true },
    };

    try std.testing.expectEqualSlices(Args(a1), exp, &p1);
}
