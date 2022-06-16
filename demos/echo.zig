const std = @import("std");
const vx = @import("vortex").Vortex;
const assert = std.debug.assert;

const clap = @import("clap");

const Timespec = vx.Timespec;
const Histogram = vx.metrics.DefaultLog2HdrHistogram(Timespec);

const Server = struct {
    alloc: std.mem.Allocator,
    addr: std.net.Address,
    msg_size: usize,

    fn session(server: *@This(), stream: *vx.net.TcpStream) !void {
        vx.event.emit(SessionStartEvent, .{ .addr = stream.peer });
        defer vx.event.emit(SessionEndEvent, .{ .addr = stream.peer });

        var buf = try server.alloc.alloc(u8, server.msg_size);
        defer server.alloc.free(buf);

        while (true) {
            const msg_zone = vx.tracing.ZoneNC(@src(), "Message handler", 0x00_ff_00_00);
            defer msg_zone.End();

            // await a message from the client
            const rc = try stream.recv(buf, null);
            if (rc == 0) break; // client disconnected

            // send back what we received
            const sc = try stream.send(buf[0..rc], null);
            assert(rc == sc);
        }
    }

    fn start(server: *@This()) !void {
        vx.event.emit(ServerStartEvent, .{ .addr = server.addr });

        var l = try vx.net.startTcpListener(server.addr, 64);
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
            try vx.task.spawn(&client.task, .{ server, &client.stream }, null);
        }

        // NOTE: for now we do not have a clean shutdown for the server
    }
};

const Client = struct {
    alloc: std.mem.Allocator,
    addr: std.net.Address,
    num_conn: usize,
    messages: usize,
    msg_size: usize,
    total_tracker: Histogram = .{},

    fn connection(client: *@This(), conn_tracker: *Histogram) !void {
        vx.event.emit(SessionStartEvent, .{ .addr = client.addr });
        defer vx.event.emit(SessionEndEvent, .{ .addr = client.addr });

        var stream = try vx.net.openTcpStream(client.addr, null);
        defer stream.close();

        var buf = try client.alloc.alloc(u8, client.msg_size);
        defer client.alloc.free(buf);

        var count: usize = 0;
        while (count < client.messages) : (count += 1) {
            const t1 = vx.time.now();
            defer conn_tracker.add(vx.time.now() - t1);

            const sc = try stream.send(buf, null);
            assert(sc == client.msg_size);

            const rc = try stream.recv(buf, null);
            assert(rc == client.msg_size);
        }

        // conn_tracker.dump();
    }

    fn start(client: *@This()) !void {
        vx.event.emit(ClientStartEvent, .{ .addr = client.addr });

        const ConnectionState = struct {
            task: vx.task.SpawnHandle(connection),
            tracker: Histogram,
        };

        var connections = try client.alloc.alloc(ConnectionState, client.num_conn);
        defer client.alloc.free(connections);

        for (connections) |*conn| {
            conn.tracker = .{};

            // spawn a new task for the connection
            try vx.task.spawn(
                &conn.task,
                .{ client, &conn.tracker },
                null,
            );
        }

        for (connections) |*conn| {
            try conn.task.join();

            client.total_tracker.merge(&conn.tracker);
        }

        // client.total_tracker.dump();

        const qs = [_]comptime_float{ 0.5, 0.9, 0.99 };
        var qr: [qs.len]Timespec = undefined;
        client.total_tracker.quantileValues(&qs, &qr);

        vx.event.emit(ClientFinishEvent, .{
            .p50 = qr[0],
            .p90 = qr[1],
            .p99 = qr[2],
            .min = client.total_tracker.min,
            .max = client.total_tracker.max,
            .count = client.total_tracker.count,
        });
    }
};

pub fn main() !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\-s, --server             Run an echo server on address:port
        \\-c, --clients <usize>    Number of client connections to address:port
        \\-m, --messages <usize>   Number of messages to send
        \\-p, --payload <usize>    Payload size (bytes)
        \\<address>
        \\
    );

    const parsers = comptime .{
        .usize = clap.parsers.int(usize, 0),
        .address = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
    }) catch |err| {
        // Report useful error and exit
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return;
    };
    defer res.deinit();

    if (res.args.help or res.positionals.len != 1) {
        // TODO: print arg0?
        std.debug.print("Usage: ", .{});
        _ = try clap.usage(std.io.getStdErr().writer(), clap.Help, &params);
        std.debug.print("\n", .{});

        std.debug.print("Options:\n", .{});
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }

    // parse the address positional into an ipv4:port pair
    // TODO: don't panic. Provide a clean error message.
    var it = std.mem.split(u8, res.positionals[0], ":");
    const ipv4 = it.next() orelse @panic("Malformed address");
    const pstr = it.next() orelse @panic("Malformed port");

    // TODO: catch these errors and provide clean error message.
    const port = try std.fmt.parseInt(u16, pstr, 10);
    const addr = try std.net.Address.parseIp4(ipv4, port);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (@import("builtin").mode == .Debug) {
        std.debug.assert(!gpa.deinit());
    };

    const alloc = gpa.allocator();

    try vx.init(alloc, vx.DefaultTestConfig);
    defer vx.deinit(alloc);

    if (res.args.server) {
        var server = Server{
            .alloc = alloc,
            .addr = addr,
            .msg_size = res.args.payload orelse 64,
        };
        try vx.run(Server.start, .{&server});
    } else if (res.args.clients) |num_clients| {
        var client = Client{
            .alloc = alloc,
            .addr = addr,
            .num_conn = num_clients,
            .messages = res.args.messages orelse 10000,
            .msg_size = res.args.payload orelse 64,
        };
        try vx.run(Client.start, .{&client});
    } else {
        std.debug.print("Must provide either --server or --client\n", .{});
        return;
    }
}

const ScopedRegistry = vx.event.Registry("demo.echo", enum {
    server_start,
    session_start,
    session_end,
    client_start,
    client_finish,
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

const ClientStartEvent = ScopedRegistry.register(.client_start, .info, struct {
    addr: std.net.Address,
});

const ClientFinishEvent = ScopedRegistry.register(.client_finish, .info, struct {
    p50: Timespec,
    p90: Timespec,
    p99: Timespec,
    min: Timespec,
    max: Timespec,
    count: usize,
});
