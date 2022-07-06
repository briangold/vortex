const std = @import("std");
const os = std.os;

const vortex = @import("../vortex.zig");

const alloc = std.testing.allocator;

// NOTE: for some reason, getpid() isn't in std.os, it's only in std.os.linux
extern "c" fn getpid() c_int;

fn test_signal(comptime V: type) !void {
    const SupportedSignal = V.signal.SupportedSignal;
    const SignalReader = V.signal.SignalReader;
    const SpawnHandle = V.task.SpawnHandle;
    const spawn = V.task.spawn;
    const emit = V.event.emit;

    const ScopedRegistry = V.event.Registry("test.signal", enum {
        signal_raised,
        signal_wait,
        signal_wake,
    });

    const SignalRaised = ScopedRegistry.register(
        .signal_raised,
        .debug,
        struct { signal: SupportedSignal },
    );

    const SignalWait = ScopedRegistry.register(.signal_wait, .debug, struct {});
    const SignalWake = ScopedRegistry.register(.signal_wake, .debug, struct {});

    const init = struct {
        fn child(sig: SupportedSignal) !void {
            emit(SignalRaised, .{ .signal = sig });

            // trigger the signal
            try os.kill(getpid(), @intCast(u8, @enumToInt(sig)));

            // wait indefinitely
            try V.time.sleep(std.math.maxInt(V.Timespec));
        }

        fn sigwait(reader: SignalReader) !void {
            emit(SignalWait, .{});
            try reader.wait(null);
            emit(SignalWake, .{});
        }

        fn start() !void {
            const sig = SupportedSignal.sigterm;

            const sig_reader = try V.signal.register(sig);

            var ch: SpawnHandle(child) = undefined;
            var sh: SpawnHandle(sigwait) = undefined;
            try spawn(&ch, .{sig}, null);
            try spawn(&sh, .{sig_reader}, null);

            switch (try V.task.select(.{
                .child = &ch,
                .signal = &sh,
            })) {
                .child => |err| return err,
                .signal => |err| return err,
            }
        }
    }.start;

    try V.testing.runTest(alloc, V.DefaultTestConfig, init, .{});
}

test "signal" {
    try test_signal(vortex.Vortex);
}
