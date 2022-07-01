const std = @import("std");
const assert = std.debug.assert;

const Timespec = @import("../clock.zig").Timespec;

const scheduler = @import("../scheduler.zig");
const Scheduler = scheduler.SimScheduler;
const CancelToken = scheduler.CancelToken;

const Descriptor = i32;

pub const InitError = anyerror; // TODO: narrow
const SocketError = anyerror; // TODO: narrow
const BindError = anyerror; // TODO: narrow
const ListenError = anyerror; // TODO: narrow
const SetSockOptError = anyerror; // TODO: narrow
const GetSockNameError = anyerror; // TODO: narrow
const PrepError = anyerror; // TODO: narrow
const CompleteError = anyerror; // TODO: narrow

pub const SimPlatform = struct {
    sched: *Scheduler,
    pending: usize,

    pub fn init(sched: *Scheduler, _: std.mem.Allocator) InitError!SimPlatform {
        return SimPlatform{
            .sched = sched,
            .pending = 0,
        };
    }

    pub fn deinit(_: *SimPlatform, _: std.mem.Allocator) void {}

    /// Polls for event completions, triggering the registered wakeup callback
    /// (typically to reschedule a task for continued execution).  Waits up to
    /// `timeout' nanoseconds for a completion. Returns the number of
    /// completions handled.
    pub fn poll(_: *SimPlatform, timeout_ns: Timespec) usize {
        _ = timeout_ns;
        unreachable; // TODO: SimPlatform poll()
    }

    pub fn hasPending(platform: *SimPlatform) bool {
        return platform.pending != 0;
    }

    pub fn socket(
        _: *SimPlatform,
        domain: u32,
        socket_type: u32,
        protocol: u32,
    ) SocketError!Descriptor {
        _ = domain;
        _ = socket_type;
        _ = protocol;
        unreachable; // TODO: socket() sim
    }

    pub fn close(
        _: *SimPlatform,
        sock: Descriptor,
    ) void {
        _ = sock;
        unreachable; // TODO: close() sim
    }

    pub fn bind(
        _: *SimPlatform,
        sock: Descriptor,
        addr: *const std.os.sockaddr,
        len: std.os.socklen_t,
    ) BindError!void {
        _ = sock;
        _ = addr;
        _ = len;
        unreachable; // TODO: bind() sim
    }

    pub fn listen(
        _: *SimPlatform,
        sock: Descriptor,
        backlog: u31,
    ) ListenError!void {
        _ = sock;
        _ = backlog;
        unreachable; // TODO: listen() sim
    }

    pub fn setsockopt(
        _: *SimPlatform,
        fd: Descriptor,
        level: u32,
        optname: u32,
        opt: []const u8,
    ) SetSockOptError!void {
        _ = fd;
        _ = level;
        _ = optname;
        _ = opt;
        unreachable; // TODO: setsockopt() sim
    }

    pub fn getsockname(
        _: *SimPlatform,
        sock: Descriptor,
        addr: *std.os.sockaddr,
        addrlen: *std.os.socklen_t,
    ) GetSockNameError!void {
        _ = sock;
        _ = addr;
        _ = addrlen;
        unreachable; // TODO: getsockname() sim
    }

    pub fn sleep(platform: *SimPlatform, interval: Timespec) !void {
        var op = IoOperation{
            .platform = platform,
            .args = .sleep,
        };
        try platform.sched.suspendTask(interval, &op);
        _ = try op.complete();
    }

    pub fn accept(
        platform: *SimPlatform,
        listen_fd: Descriptor,
        addr: *std.os.sockaddr,
        addrlen: *std.os.socklen_t,
        flags: u32,
        _: Timespec,
    ) !Descriptor {
        return IoOperation{
            .platform = platform,
            .args = .{ .accept = .{
                .listen_fd = listen_fd,
                .addr = addr,
                .addrlen = addrlen,
                .flags = flags,
            } },
        };
    }

    const IoOperation = struct {
        platform: *SimPlatform,

        args: union(enum) {
            sleep,
            accept: struct {
                listen_fd: Descriptor,
                addr: *std.os.sockaddr,
                addrlen: *std.os.socklen_t,
                flags: u32,
            },
            connect,
            recv,
            send,
        },

        pub fn prep(
            op: *IoOperation,
            timeout: Timespec,
            comptime callback: anytype,
            callback_ctx: anytype,
            callback_data: usize,
        ) PrepError!void {
            _ = op;
            _ = timeout;
            _ = callback;
            _ = callback_ctx;
            _ = callback_data;
            unreachable; // TODO: prep
        }

        pub fn complete(op: *IoOperation) CompleteError!usize {
            _ = op;
            unreachable; // TODO: complete
        }

        fn cancel(op: *IoOperation) void {
            _ = op;
            unreachable; // TODO: cancel
        }

        pub fn cancelToken(op: *IoOperation) CancelToken {
            return CancelToken.init(op, cancel);
        }
    };
};
