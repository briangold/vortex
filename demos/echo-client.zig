const std = @import("std");
const vx = @import("vortex").Vortex;
const assert = std.debug.assert;

const Timespec = vx.Timespec;
const Histogram = vx.metrics.DefaultLog2HdrHistogram(Timespec);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (@import("builtin").mode == .Debug) {
        std.debug.assert(!gpa.deinit());
    };

    const Client = struct {
        lat_tracker: Histogram = .{},

        fn connection(
            addr: std.net.Address,
            conn_tracker: *Histogram,
        ) !void {
            vx.event.emit(SessionStartEvent, .{});
            defer vx.event.emit(SessionEndEvent, .{});

            var stream = try vx.net.openTcpStream(addr, null);
            defer stream.close();

            const msg_size = 4;
            const msg_count = 10000;

            var buf: [msg_size]u8 = undefined;
            var count: usize = 0;
            while (count < msg_count) : (count += 1) {
                const t1 = vx.time.now();
                defer conn_tracker.add(vx.time.now() - t1);

                const sc = try stream.send(&buf, null);
                assert(sc == buf.len);

                const rc = try stream.recv(&buf, null);
                assert(rc == buf.len);
            }

            // conn_tracker.dump();
        }

        fn start(self: *@This(), addr: std.net.Address) !void {
            vx.event.emit(ClientStartEvent, .{ .addr = addr });

            const num_conn = 4;
            const ConnectionState = struct {
                task: vx.task.SpawnHandle(connection),
                lat_tracker: Histogram,
            };
            var connections: [num_conn]ConnectionState = undefined;

            for (connections) |*conn| {
                conn.lat_tracker = .{};

                // spawn a new task for the connection
                try vx.task.spawn(
                    &conn.task,
                    .{ addr, &conn.lat_tracker },
                    null,
                );
            }

            for (connections) |*conn| {
                try conn.task.join();

                self.lat_tracker.merge(&conn.lat_tracker);
            }

            // self.lat_tracker.dump();

            const qs = [_]comptime_float{ 0.5, 0.9, 0.99 };
            var qr: [qs.len]Timespec = undefined;
            self.lat_tracker.quantileValues(&qs, &qr);

            vx.event.emit(ClientFinishEvent, .{
                .p50 = qr[0],
                .p90 = qr[1],
                .p99 = qr[2],
                .min = self.lat_tracker.min,
                .max = self.lat_tracker.max,
                .count = self.lat_tracker.count,
            });
        }
    };

    const ip4: []const u8 = "0.0.0.0";
    const port: u16 = 8888;
    const addr = try std.net.Address.parseIp4(ip4, port);

    const alloc = gpa.allocator();

    try vx.init(alloc, vx.DefaultTestConfig);
    defer vx.deinit(alloc);

    var client = Client{};
    try vx.run(Client.start, .{ &client, addr });
}

const ScopedRegistry = vx.event.Registry("demo.echo", enum {
    client_start,
    client_finish,
    session_start,
    session_end,
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

const SessionStartEvent = ScopedRegistry.register(.session_start, .info, struct {});

const SessionEndEvent = ScopedRegistry.register(.session_end, .info, struct {});
