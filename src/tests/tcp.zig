const std = @import("std");
const vortex = @import("../vortex.zig");
const net = @import("../network.zig");

const alloc = std.testing.allocator;

fn test_hello(comptime V: type) !void {
    const Address = std.net.Address;

    const State = std.atomic.Atomic(enum(u8) {
        start,
        listening,
        done,
    });

    const init = struct {
        fn server(addr: Address, state: *State) !void {
            const io_timeout = std.time.ns_per_s;

            var l = try V.net.startTcpListener(addr, 64);
            defer l.close();

            state.store(.listening, .Release);

            var stream = try l.accept(io_timeout);
            defer stream.close();

            try std.testing.expect(stream.fd > 0);

            // Should the recv hit an error, we still want to signal to the
            // client that we're done, to ensure we crash rather than hang.
            // We have to be careful of the order of defers, so this barrier
            // runs before the sockets are closed.
            defer state.store(.done, .Release);

            var buf: [32]u8 = undefined;
            const nb = try stream.recv(&buf, io_timeout);

            try std.testing.expect(std.mem.eql(u8, "Hello, world", buf[0..nb]));
        }

        fn client(addr: Address, state: *State) !void {
            const io_timeout = std.time.ns_per_s;

            while (state.load(.Acquire) == .start) {
                try V.time.sleep(std.time.ns_per_ms);
            }

            var stream = try V.net.openTcpStream(addr, io_timeout);
            defer stream.close();

            try std.testing.expect(stream.fd > 0);

            const msg = "Hello, world";
            const nb = try stream.send(msg, io_timeout);

            try std.testing.expectEqual(msg.len, nb);

            // If the client exits, we tear down the connection and the server
            // may not have received the reply. So wait.
            while (state.load(.Acquire) != .done) {
                try V.time.sleep(std.time.ns_per_ms);
            }
        }

        fn start(timeout: V.Timespec) !void {
            var state = State.init(.start);
            var srv: V.task.SpawnHandle(server) = undefined;
            var cli: V.task.SpawnHandle(client) = undefined;

            const addr = try V.testing.unusedTcpPort();

            try V.task.spawn(&srv, .{ addr, &state }, timeout);
            defer srv.join() catch |err| {
                std.debug.panic("Server error: {s}\n", .{@errorName(err)});
            };

            try V.task.spawn(&cli, .{ addr, &state }, timeout);
            defer cli.join() catch |err| {
                std.debug.panic("Client error: {s}\n", .{@errorName(err)});
            };
        }
    }.start;

    try V.testing.runTest(
        alloc,
        V.DefaultTestConfig,
        init,
        .{std.time.ns_per_s},
    );
}

test "hello" {
    try test_hello(vortex.Vortex);
}

fn test_timeout(comptime V: type) !void {
    const init = struct {
        fn start(timeout: V.Timespec) !void {
            const addr = try V.testing.unusedTcpPort();

            var l = try V.net.startTcpListener(addr, 64);
            defer l.close();

            _ = try l.accept(timeout);

            unreachable; // Timeout should have been triggered
        }
    }.start;

    try std.testing.expectError(
        error.IoCanceled,
        V.testing.runTest(
            alloc,
            V.DefaultTestConfig,
            init,
            .{std.time.ns_per_ms},
        ),
    );
}

test "timeout" {
    try test_timeout(vortex.Vortex);
}
