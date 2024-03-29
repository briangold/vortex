const std = @import("std");
const ztracy = @import("deps/ztracy/build.zig");

const Builder = std.build.Builder;
const Step = std.build.Step;
const FileSource = std.build.FileSource;

pub const VxBuildOptions = struct {
    enable_tracy: bool = false,
    force_reactor: bool = false,
};

pub fn addVortexPackage(
    libexe: *std.build.LibExeObjStep,
    options: VxBuildOptions,
) void {
    const b = libexe.builder;
    const exe_options = b.addOptions();
    exe_options.addOption(bool, "enable_tracy", options.enable_tracy);
    exe_options.addOption(bool, "force_reactor", options.force_reactor);

    const options_pkg = exe_options.getPackage("build_options");
    const tracy_pkg = ztracy.getPkg(b, options_pkg);

    libexe.addPackage(getVortexPkg(&[_]std.build.Pkg{ tracy_pkg, options_pkg }));
    libexe.linkLibC();

    ztracy.link(libexe, options.enable_tracy, .{ .fibers = true });
}

fn getVortexPkg(deps: ?[]const std.build.Pkg) std.build.Pkg {
    const vortex = std.build.Pkg{
        .name = "vortex",
        .source = FileSource.relative("vortex.zig"),
        .dependencies = deps,
    };
    return vortex;
}

const demo_pkgs = struct {
    const clap = std.build.Pkg{
        .name = "clap",
        .source = FileSource.relative("deps/zig-clap/clap.zig"),
        .dependencies = &[_]std.build.Pkg{},
    };
};

fn addDemo(
    b: *Builder,
    comptime demo: anytype,
    options: anytype,
) !void {
    const exe = b.addExecutable(demo.name, demo.path);

    addVortexPackage(exe, .{
        .enable_tracy = options.enable_tracy,
        .force_reactor = options.force_reactor,
    });

    exe.setTarget(options.target);
    exe.setBuildMode(options.mode);
    exe.addPackage(demo_pkgs.clap);

    const install_exe = b.addInstallArtifact(exe);
    const demo_step = b.step(demo.name, "Build " ++ demo.name ++ " demo");
    demo_step.dependOn(&install_exe.step);
}

fn addFuzzer(b: *Builder, comptime fuzzer: anytype) !void {
    const fuzz_lib = b.addStaticLibrary(fuzzer.name ++ "-lib", fuzzer.path);
    fuzz_lib.setBuildMode(.Debug);
    fuzz_lib.addPackage(getVortexPkg(null)); // TODO: build a tracy package here?
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;

    const fuzz_executable_name = fuzzer.name ++ "-fuzz";
    const fuzz_exe_path = try std.fs.path.join(
        b.allocator,
        &.{ b.cache_root, fuzz_executable_name },
    );

    // We want `afl-clang-lto -o path/to/output path/to/library`
    const fuzz_compile = b.addSystemCommand(
        &.{ "afl-clang-lto", "-o", fuzz_exe_path },
    );
    // Add the path to the library file to afl-clang-lto's args
    fuzz_compile.addArtifactArg(fuzz_lib);

    // Install the cached output to the install 'bin' path
    const fuzz_install = b.addInstallBinFile(
        .{ .path = fuzz_exe_path },
        fuzz_executable_name,
    );

    // Add a top-level step that compiles and installs the fuzz executable
    const fuzz_compile_run = b.step(
        fuzzer.name ++ "-fuzz",
        "Build executable for fuzz testing using afl-clang-lto",
    );
    fuzz_compile_run.dependOn(&fuzz_compile.step);
    fuzz_compile_run.dependOn(&fuzz_install.step);

    // Compile a companion exe for debugging crashes
    const fuzz_debug_exe = b.addExecutable(
        fuzzer.name ++ "-debug",
        fuzzer.path,
    );
    fuzz_debug_exe.setBuildMode(.Debug);
    fuzz_debug_exe.addPackage(getVortexPkg(null)); // TODO: build tracy package here?

    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe);
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);
}

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const enable_tracy = b.option(bool, "enable-tracy", "Enable Tracy profiler") orelse false;
    const force_reactor = b.option(bool, "force-reactor", "Use readiness (epoll) even when completion API (io_uring) available") orelse false;

    const demos = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "one", .path = "demos/one.zig" },
        .{ .name = "echo", .path = "demos/echo.zig" },
    };

    inline for (demos) |demo| {
        try addDemo(b, demo, .{
            .target = target,
            .mode = mode,
            .enable_tracy = enable_tracy,
            .force_reactor = force_reactor,
        });
    }

    const list_demo_step = b.step("list-demos", "List demos to run");
    list_demo_step.dependOn(createListStep(b, "demo", demos));

    ////////////

    const fuzzers = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "cancel", .path = "tests/cancel-fuzz.zig" },
    };

    inline for (fuzzers) |fuzzer| {
        try addFuzzer(b, fuzzer);
    }

    const list_fuzz_step = b.step("list-fuzzers", "List fuzzers");
    list_fuzz_step.dependOn(createListStep(b, "fuzzer", fuzzers));

    ////////////

    const main_tests = b.addTest("vortex.zig");
    main_tests.setBuildMode(mode);
    main_tests.linkLibC();

    const test_opt = b.addOptions();
    test_opt.addOption(bool, "enable_tracy", false);
    test_opt.addOption(bool, "force_reactor", force_reactor);
    const options_pkg = test_opt.getPackage("build_options");

    const ztracy_pkg = ztracy.getPkg(b, options_pkg);
    main_tests.addPackage(ztracy_pkg);
    main_tests.addPackage(options_pkg);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    ////////////

}

fn createListStep(
    b: *Builder,
    comptime prefix: []const u8,
    comptime list: anytype,
) *Step {
    const make = struct {
        fn inner(_: *Step) anyerror!void {
            std.debug.print("Available {s}s:\n", .{prefix});
            inline for (list) |item| {
                std.debug.print("  {s}\n", .{item.name});
            }
            std.debug.print(
                "\nBuild with \"zig build {s}-(name)\"\n",
                .{prefix},
            );
        }
    }.inner;

    var step = b.allocator.create(Step) catch unreachable;
    step.* = Step.init(.custom, "list-demos", b.allocator, make);

    return step;
}
