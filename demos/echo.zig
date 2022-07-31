const std = @import("std");
const vx = @import("vortex").Vortex;
const assert = std.debug.assert;

const clap = @import("clap");

const Timespec = vx.Timespec;
const Histogram = vx.metrics.DefaultLog2HdrHistogram(Timespec);
const TcpStreamChannel = vx.sync.Channel(vx.net.TcpStream);

const Server = struct {
    alloc: std.mem.Allocator,
    addr: std.net.Address,
    msg_size: usize,
    num_conn: usize,
    chan: TcpStreamChannel,

    fn connWorker(server: *@This()) !void {
        var buf = try server.alloc.alloc(u8, server.msg_size);
        defer server.alloc.free(buf);

        while (true) {
            var stream = try server.chan.pop();

            vx.event.emit(SessionStartEvent, .{ .addr = stream.peer });
            defer vx.event.emit(SessionEndEvent, .{ .addr = stream.peer });

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
    }

    fn listen(server: *@This()) !void {
        var l = try vx.net.startTcpListener(server.addr, 64);
        defer l.close();

        var workers = try server.alloc.alloc(
            vx.task.SpawnHandle(connWorker),
            server.num_conn,
        );
        defer server.alloc.free(workers);

        // spawn connection pool
        for (workers) |*w, i| {
            // If spawn fails in a loop, the parent task will attempt to
            // cancel tasks that haven't been initialized properly, leading
            // to a segfault. TODO: make this more ergonomic.
            vx.task.spawn(w, .{server}, null) catch |err|
                std.debug.panic("Unable to spawn worker {d}: {}", .{ i, err });
        }

        // defer joining so when the listen task is cancelled this block runs
        defer {
            for (workers) |*w| {
                w.join() catch |err| switch (err) {
                    error.TaskCancelled => {},
                    else => std.debug.panic("Unable to join worker: {}", .{err}),
                };
            }
        }

        // main serving loop: accept a connection and push to session tasks
        while (true) {
            const stream = try l.accept(null);

            try server.chan.push(stream);
        }
    }

    fn shutdown(reader: vx.signal.SignalReader) !void {
        try reader.wait(null);
    }

    fn enable_debug(reader: vx.signal.SignalReader) !void {
        try reader.wait(null);
        vx.event.setLevel(.debug);
    }

    fn start(server: *@This()) !void {
        vx.event.emit(ServerStartEvent, .{ .addr = server.addr });

        // register handler for SIGINT (ctrl-c)
        const sig_reader = try vx.signal.register(.sigint);
        const dbg_reader = try vx.signal.register(.sighup);

        var lh: vx.task.SpawnHandle(listen) = undefined;
        try vx.task.spawn(&lh, .{server}, null);

        var sh: vx.task.SpawnHandle(shutdown) = undefined;
        try vx.task.spawn(&sh, .{sig_reader}, null);

        var dh: vx.task.SpawnHandle(enable_debug) = undefined;
        try vx.task.spawn(&dh, .{dbg_reader}, null);

        switch (try vx.task.select(.{
            .listen = &lh,
            .shutdown = &sh,
        })) {
            .listen => @panic("Listener exited unexpectedly"),
            .shutdown => vx.event.emit(ServerShutdownEvent, .{}),
        }

        dh.cancel();
        dh.join() catch {};
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
            vx.task.spawn(
                &conn.task,
                .{ client, &conn.tracker },
                null,
            ) catch |err| {
                std.debug.panic("Unable to spawn task: {}", .{err});
            };
        }

        for (connections) |*conn| {
            conn.task.join() catch |err| {
                std.debug.panic("Error: {}", .{err});
            };

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
        \\-c, --conn <usize>       Number of connections to address:port
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
        const chan_size = 1024; // TODO: make this a CLI arg?
        var server = Server{
            .alloc = alloc,
            .addr = addr,
            .msg_size = res.args.payload orelse 64,
            .num_conn = res.args.conn orelse 1,
            .chan = try TcpStreamChannel.init(alloc, chan_size),
        };
        defer server.chan.deinit(alloc);

        try vx.run(Server.start, .{&server});
    } else if (res.args.conn) |num_clients| {
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
    server_shutdown,
    session_start,
    session_end,
    client_start,
    client_finish,
});

const ServerStartEvent = ScopedRegistry.register(.server_start, .info, struct {
    addr: std.net.Address,
});

const ServerShutdownEvent = ScopedRegistry.register(.server_shutdown, .info, struct {});

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
