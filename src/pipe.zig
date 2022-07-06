const std = @import("std");
const os = std.os;

const Timespec = @import("clock.zig").Timespec;
const max_time = @import("clock.zig").max_time;
const RuntimeImpl = @import("runtime.zig").RuntimeImpl;

pub fn Impl(comptime R: type) type {
    return struct {
        const Self = @This();
        const Runtime = R;
        const Platform = R.Platform;

        pub const PipePair = struct {
            rt: *Runtime,
            rd: os.fd_t,
            wr: os.fd_t,

            pub fn init(rt: *Runtime) !PipePair {
                // TODO: rt should provide a pipe-creation method so a sim
                // version can interpose os, similar to socket methods
                const fds = try os.pipe2(os.O.NONBLOCK | os.O.CLOEXEC);
                return PipePair{
                    .rt = rt,
                    .rd = fds[0],
                    .wr = fds[1],
                };
            }

            pub fn deinit(pp: *PipePair) void {
                os.close(pp.rd);
                os.close(pp.wr);
            }

            pub fn read(
                pp: PipePair,
                buf: []u8,
                timeout_ns: ?Timespec,
            ) !usize {
                const timeout = timeout_ns orelse max_time;
                return pp.rt.io().read(pp.rd, buf, 0, timeout);
            }

            pub fn write(
                pp: PipePair,
                buf: []const u8,
                timeout_ns: ?Timespec,
            ) !usize {
                const timeout = timeout_ns orelse max_time;
                return pp.rt.io().write(pp.wr, buf, 0, timeout);
            }
        };
    };
}
