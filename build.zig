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

    const vx_deps = [_]std.build.Pkg{
        options_pkg,
        tracy_pkg,
    };

    libexe.addPackage(getVxPackage(&vx_deps));

    // required for signals implementation
    // TODO: refactor into signals package and pick up via build helper
    libexe.linkLibC();

    ztracy.link(libexe, options.enable_tracy, .{ .fibers = true });
}

fn getVxPackage(deps: ?[]const std.build.Pkg) std.build.Pkg {
    const vortex = std.build.Pkg{
        .name = "vortex",
        .source = FileSource.relative("vortex.zig"),
        .dependencies = deps,
    };
    return vortex;
}

const exec_pkgs = struct {
    const clap = std.build.Pkg{
        .name = "clap",
        .source = FileSource.relative("deps/zig-clap/clap.zig"),
        .dependencies = &[_]std.build.Pkg{},
    };

    const metron = std.build.Pkg{
        .name = "metron",
        .source = FileSource.relative("deps/metron/metron.zig"),
        .dependencies = &[_]std.build.Pkg{},
    };
};

fn addVxExecutable(
    b: *Builder,
    comptime def: anytype,
    options: anytype,
) !void {
    const exe = b.addExecutable(def.name, def.path);

    addVortexPackage(exe, .{
        .enable_tracy = options.enable_tracy,
        .force_reactor = options.force_reactor,
    });

    exe.setTarget(options.target);
    exe.setBuildMode(options.mode);
    exe.addPackage(exec_pkgs.clap);
    exe.addPackage(exec_pkgs.metron);

    // TODO: make this a build-time option?
    exe.omit_frame_pointer = false; // for performance analysis

    const install_exe = b.addInstallArtifact(exe);
    const exec_step = b.step(def.name, "Build " ++ def.name ++ " executable");
    exec_step.dependOn(&install_exe.step);
}

fn addFuzzer(b: *Builder, comptime fuzzer: anytype) !void {
    const fuzz_lib = b.addStaticLibrary(fuzzer.name ++ "-lib", fuzzer.path);
    fuzz_lib.setBuildMode(.Debug);
    fuzz_lib.addPackage(getVxPackage(null)); // TODO: build a tracy package here?
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
    fuzz_debug_exe.addPackage(getVxPackage(null)); // TODO: build tracy package here?

    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe);
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);
}

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const enable_tracy = b.option(bool, "enable-tracy", "Enable Tracy profiler") orelse false;
    const force_reactor = b.option(bool, "force-reactor", "Use readiness (epoll) even when completion API (io_uring) available") orelse false;

    const ExecDef = struct {
        name: []const u8,
        path: []const u8,
    };

    const demos = [_]ExecDef{
        .{ .name = "one", .path = "demos/one.zig" },
        .{ .name = "echo", .path = "demos/echo.zig" },
    };

    const benchmarks = [_]ExecDef{
        .{ .name = "sleeper", .path = "benchmarks/sleeper.zig" },
    };

    inline for (demos ++ benchmarks) |def| {
        try addVxExecutable(b, def, .{
            .target = target,
            .mode = mode,
            .enable_tracy = enable_tracy,
            .force_reactor = force_reactor,
        });
    }

    const list_demo_step = b.step("list-demos", "List demos");
    list_demo_step.dependOn(createListStep(b, "demo", demos));

    const list_bench_step = b.step("list-benchmarks", "List benchmarks");
    list_bench_step.dependOn(createListStep(b, "benchmarks", benchmarks));

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
            std.debug.print("\nBuild with \"zig build (name)\"\n", .{});
        }
    }.inner;

    var step = b.allocator.create(Step) catch unreachable;
    step.* = Step.init(.custom, "list-demos", b.allocator, make);

    return step;
}
