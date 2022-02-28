const std = @import("std");
const vx = @import("vortex").Vortex;
const assert = std.debug.assert;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (@import("builtin").mode == .Debug) {
        std.debug.assert(!gpa.deinit());
    };

    const Server = struct {
        fn session(stream: *vx.net.TcpStream) !void {
            vx.event.emit(SessionStartEvent, .{ .addr = stream.peer });
            defer vx.event.emit(SessionEndEvent, .{ .addr = stream.peer });

            var buf: [4096]u8 = undefined;
            while (true) {
                // await a message from the client
                const rc = try stream.recv(&buf, null);
                if (rc == 0) break; // client disconnected

                // send back what we received
                const sc = try stream.send(buf[0..rc], null);
                assert(rc == sc);
            }
        }

        fn start(addr: std.net.Address) !void {
            vx.event.emit(ServerStartEvent, .{ .addr = addr });

            var l = try vx.net.startTcpListener(addr, 64);
            defer l.close();

            // TODO: conslidate client & server and share constants
            const max_clients = 1024;
            const State = struct {
                stream: vx.net.TcpStream,
                task: vx.task.SpawnHandle(session),
            };
            var clients: [max_clients]State = undefined;

            for (clients) |*client| {
                // accept a connection on the listener
                client.stream = try l.accept(null);

                // spawn a new task for the session
                try vx.task.spawn(&client.task, .{&client.stream}, null);
            }

            // NOTE: for now we do not have a clean shutdown for the server
        }
    };

    const ip4: []const u8 = "0.0.0.0";
    const port: u16 = 8888;
    const addr = try std.net.Address.parseIp4(ip4, port);

    const alloc = gpa.allocator();

    try vx.init(alloc, vx.DefaultTestConfig);
    defer vx.deinit(alloc);

    try vx.run(Server.start, .{addr});
}

const ScopedRegistry = vx.event.Registry("demo.echo", enum {
    server_start,
    session_start,
    session_end,
});

const ServerStartEvent = ScopedRegistry.register(.server_start, .info, struct {
    addr: std.net.Address,
});

const SessionStartEvent = ScopedRegistry.register(.session_start, .info, struct {
    addr: std.net.Address,
});

const SessionEndEvent = ScopedRegistry.register(.session_end, .info, struct {
    addr: std.net.Address,
});
