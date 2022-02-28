const std = @import("std");
const os = std.os;

// The set of supported POSIX socketcall APIs with an additional (ignored) parameter
// for the loop type. These are included in various loop implementations when
// a simple pass-through to the OS is desired.

pub fn socket(_: anytype, domain: u32, socket_type: u32, protocol: u32) os.SocketError!os.socket_t {
    return os.socket(domain, socket_type, protocol);
}

pub fn close(_: anytype, sock: os.socket_t) void {
    os.close(sock);
}

pub fn bind(_: anytype, sock: os.socket_t, addr: *const os.sockaddr, len: os.socklen_t) os.BindError!void {
    return os.bind(sock, addr, len);
}

pub fn listen(_: anytype, sock: os.socket_t, backlog: u31) os.ListenError!void {
    return os.listen(sock, backlog);
}

pub fn getsockname(_: anytype, sock: os.socket_t, addr: *os.sockaddr, addrlen: *os.socklen_t) os.GetSockNameError!void {
    return os.getsockname(sock, addr, addrlen);
}

pub fn getpeername(_: anytype, sock: os.socket_t, addr: *os.sockaddr, addrlen: *os.socklen_t) os.GetSockNameError!void {
    return os.getpeername(sock, addr, addrlen);
}

pub fn setsockopt(_: anytype, fd: os.socket_t, level: u32, optname: u32, opt: []const u8) os.SetSockOptError!void {
    return os.setsockopt(fd, level, optname, opt);
}

pub fn getsockopt(_: anytype, fd: i32, level: u32, optname: u32, optval: [*]u8, optlen: *os.socklen_t) usize {
    return os.system.getsockopt(fd, level, optname, optval, optlen);
}
