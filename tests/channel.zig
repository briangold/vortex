const std = @import("std");
const vortex = @import("../vortex.zig");

const alloc = std.testing.allocator;

fn test_spsc(comptime V: type) !void {
    const Channel = V.sync.Channel;
    const SpawnHandle = V.task.SpawnHandle;
    const spawn = V.task.spawn;

    const chan_size = 16;
    const num_messages = 32;

    const init = struct {
        fn sender(chan: *Channel(usize)) !void {
            var i: usize = 0;
            while (i < num_messages) : (i += 1) {
                try chan.push(i);
            }
        }

        fn receiver(chan: *Channel(usize)) !void {
            var i: usize = 0;
            while (i < num_messages) : (i += 1) {
                const v = try chan.pop();
                try std.testing.expectEqual(i, v);
            }
        }

        fn start() !void {
            var c = try Channel(usize).init(alloc, chan_size);
            defer c.deinit(alloc);

            var sh: SpawnHandle(sender) = undefined;
            var rh: SpawnHandle(receiver) = undefined;
            try spawn(&sh, .{&c}, null);
            try spawn(&rh, .{&c}, null);
            try sh.join();
            try rh.join();
        }
    }.start;

    try V.testing.runTest(alloc, V.DefaultTestConfig, init, .{});
}

fn test_channel(
    comptime V: type,
    comptime chan_size: comptime_int,
    comptime num_senders: comptime_int,
    comptime num_receivers: comptime_int,
    comptime num_messages: comptime_int,
) !void {
    const Channel = V.sync.Channel;
    const SpawnHandle = V.task.SpawnHandle;
    const spawn = V.task.spawn;

    const init = struct {
        fn sender(chan: *Channel(usize), idx: usize) !void {
            var i: usize = idx;
            while (i < num_messages) : (i += num_senders) {
                try chan.push(i);
            }
        }

        fn receiver(chan: *Channel(usize)) !usize {
            var sum: usize = 0;
            var i: usize = 0;
            while (i < num_messages) : (i += num_receivers) {
                sum += try chan.pop();
            }
            return sum;
        }

        fn start() !void {
            var c = try Channel(usize).init(alloc, chan_size);
            defer c.deinit(alloc);

            var senders: [num_senders]SpawnHandle(sender) = undefined;
            for (senders) |*sh, i| {
                spawn(sh, .{ &c, i }, null) catch |err|
                    std.debug.panic("Error spawning sender: {}", .{err});
            }

            var receivers: [num_receivers]SpawnHandle(receiver) = undefined;
            for (receivers) |*rh| {
                spawn(rh, .{&c}, null) catch |err|
                    std.debug.panic("Error spawning receiver: {}", .{err});
            }

            var sum: usize = 0;
            for (senders) |*sh| {
                sh.join() catch |err|
                    std.debug.panic("Error joining sender: {}", .{err});
            }
            for (receivers) |*rh| {
                sum += rh.join() catch |err|
                    std.debug.panic("Error joining receiver: {}", .{err});
            }

            try std.testing.expectEqual(
                @as(usize, num_messages * (num_messages - 1) / 2),
                sum,
            );
        }
    }.start;

    try V.testing.runTest(alloc, V.DefaultTestConfig, init, .{});
}

test "channel" {
    // also validates ordering on the channel
    try test_spsc(vortex.Vortex);

    try test_channel(vortex.Vortex, 16, 1, 128, 1024); // SPMC
    try test_channel(vortex.Vortex, 16, 1, 128, 1024); // SPMC
    try test_channel(vortex.Vortex, 16, 128, 1, 1024); // MPSC
    try test_channel(vortex.Vortex, 16, 128, 128, 1024); // MPMC
}
