const std = @import("std");
const builtin = @import("builtin");

const Timespec = @import("clock.zig").Timespec;
const max_time = @import("clock.zig").max_time;
const RuntimeImpl = @import("runtime.zig").RuntimeImpl;

// Portions of this code are adapted from zig-network, via MIT license:
// https://github.com/MasterQ32/zig-network (commit 6f1563a)

const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;
const is_darwin = builtin.os.tag.isDarwin();
const is_freebsd = builtin.os.tag == .freebsd;
const is_openbsd = builtin.os.tag == .openbsd;
const is_netbsd = builtin.os.tag == .netbsd;
const is_dragonfly = builtin.os.tag == .dragonfly;

// use these to test collections of OS type
const is_bsd = is_darwin or is_freebsd or is_openbsd or is_netbsd or is_dragonfly;

pub fn Impl(comptime R: type) type {
    return struct {
        const Self = @This();
        const Runtime = R;
        const IoLoop = R.IoLoop;

        pub const Listener = struct {
            rt: *Runtime,
            addr: std.net.Address,
            fd: IoLoop.Descriptor,

            pub const InitError = anyerror; // TODO: narrow

            pub fn init(
                rt: *Runtime,
                addr: std.net.Address,
                backlog: u31,
            ) InitError!Listener {
                // create listener socket at endpoint
                const fd = try rt.io().socket(
                    addr.any.family,
                    std.os.SOCK.STREAM | std.os.SOCK.CLOEXEC,
                    0,
                );

                // Enable port reuse
                var opt: c_int = 1;
                try rt.io().setsockopt(
                    fd,
                    std.os.SOL.SOCKET,
                    std.os.SO.REUSEADDR,
                    std.mem.asBytes(&opt),
                );

                // Bind
                try rt.io().bind(
                    fd,
                    &addr.any,
                    addr.getOsSockLen(),
                );

                // Listen
                try rt.io().listen(fd, backlog);

                return Listener{
                    .rt = rt,
                    .addr = addr,
                    .fd = fd,
                };
            }

            pub fn close(self: *Listener) void {
                self.rt.io().close(self.fd);
            }

            pub fn accept(
                self: *Listener,
                timeout_ns: ?Timespec,
            ) !Stream {
                var peer: std.net.Address = undefined;

                const timeout = timeout_ns orelse max_time;
                var asize: std.os.socklen_t = @sizeOf(@TypeOf(peer.any));

                const fd = try self.rt.io().accept(
                    self.fd,
                    &peer.any,
                    &asize,
                    std.os.SOCK.CLOEXEC, // flags - others may be added by loop
                    timeout,
                );

                // on bsd (incl darwin) set the NOSIGNAL once
                if (is_bsd) {
                    // set the options to ON
                    const value: c_int = 1;
                    try self.rt.io().setsockopt(
                        fd,
                        std.os.SOL.SOCKET,
                        std.os.SO.NOSIGPIPE,
                        std.mem.asBytes(&value),
                    );
                }

                return Stream{
                    .rt = self.rt,
                    .fd = fd,
                    .peer = peer,
                };
            }
        };

        pub const Stream = struct {
            rt: *Runtime,
            fd: IoLoop.Descriptor,
            peer: std.net.Address,

            pub const ConnectError = anyerror; // TODO: narrow

            pub fn connect(
                rt: *Runtime,
                target: std.net.Address,
                timeout_ns: ?Timespec,
            ) ConnectError!Stream {
                const fd = try rt.io().socket(
                    target.any.family,
                    std.os.SOCK.STREAM | std.os.SOCK.CLOEXEC,
                    0,
                );

                // on bsd (incl darwin) set the NOSIGNAL once
                if (is_bsd) {
                    // set the options to ON
                    const value: c_int = 1;
                    try rt.io().setsockopt(
                        fd,
                        std.os.SOL.SOCKET,
                        std.os.SO.NOSIGPIPE,
                        std.mem.asBytes(&value),
                    );
                }

                const timeout = timeout_ns orelse max_time;
                var endpoint = target;
                _ = try rt.io().connect(
                    fd,
                    &endpoint.any,
                    endpoint.getOsSockLen(),
                    timeout,
                );

                return Stream{
                    .rt = rt,
                    .fd = fd,
                    .peer = endpoint,
                };
            }

            pub fn close(self: *Stream) void {
                self.rt.io().close(self.fd);
            }

            pub fn recv(
                self: Stream,
                buf: []u8,
                timeout_ns: ?Timespec,
            ) !usize {
                const timeout = timeout_ns orelse max_time;
                const flags = if (is_windows or is_bsd)
                    0
                else
                    std.os.linux.MSG.NOSIGNAL;
                return self.rt.io().recv(self.fd, buf, flags, timeout);
            }

            pub fn send(
                self: Stream,
                buf: []const u8,
                timeout_ns: ?Timespec,
            ) !usize {
                const timeout = timeout_ns orelse max_time;
                const flags = if (is_windows or is_bsd)
                    0
                else
                    std.os.linux.MSG.NOSIGNAL;
                return self.rt.io().send(self.fd, buf, flags, timeout);
            }
        };

        pub const testing = struct {
            pub fn unusedTcpPort(rt: *Runtime) !std.net.Address {
                // Strategy adapted from pytest-asyncio:
                //  - create a tcp socket
                //  - bind to 0.0.0.0 with port "0"
                //  - ask OS what port we received via getsockname
                const fd = try rt.io().socket(
                    std.os.AF.INET,
                    std.os.SOCK.STREAM | std.os.SOCK.CLOEXEC,
                    0,
                );
                defer rt.io().close(fd);

                var addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
                try rt.io().bind(fd, &addr.any, addr.getOsSockLen());

                var size: std.os.socklen_t = @sizeOf(std.os.sockaddr);

                try rt.io().getsockname(fd, &addr.any, &size);

                return addr;
            }
        };
    };
}
