//! Tools for creating and emitting event records, for logging and other
//! observability means.
const std = @import("std");
const assert = std.debug.assert;
pub const Level = std.log.Level;

const ztracy = @import("ztracy");

const Timespec = @import("clock.zig").Timespec;

pub const EventWriter = std.fs.File.Writer;

pub const SyncEventWriter = struct {
    writer: EventWriter,
    mutex: *std.Thread.Mutex,
};

// The Emitter that will be used by various threads to emit registered events
// of interest.
pub fn Emitter(comptime Clock: type) type {
    return struct {
        const Self = @This();

        log_level: Level,
        sync_writer: SyncEventWriter,

        pub fn init(
            log_level: Level,
            sync_writer: SyncEventWriter,
        ) Self {
            return Self{
                .log_level = log_level,
                .sync_writer = sync_writer,
            };
        }

        pub fn emit(
            self: *Self,
            clock: *Clock,
            tid: usize,
            comptime Event: type,
            user: Event.User,
        ) void {
            // bail if this is at a higher verbosity
            if (@enumToInt(Event.level) > @enumToInt(self.log_level)) return;

            const ev = Event.init(clock.now(), user);

            var buf: [4096]u8 = undefined;
            var bw = std.io.fixedBufferStream(&buf);

            bw.writer().print("{d:>15} [{d:0>3}] {s:<9} {s:12} {s:16} ", .{
                ev.timestamp,
                tid,
                "(" ++ Event.level.asText() ++ ")",
                Event.namespace,
                @tagName(Event.code),
            }) catch @panic("Unable to write event");

            if (std.meta.fields(Event.User).len > 0) {
                bw.writer().writeAll("- ") catch @panic("Unable to write event");
            }

            inline for (std.meta.fields(Event.User)) |f| {
                bw.writer().print("{s}={any} ", .{
                    f.name,
                    @field(user, f.name),
                }) catch @panic("Unable to write event");
            }

            bw.writer().writeAll("\n") catch @panic("Unable to write event");

            // Emit to tracy - a nop unless built with -Denable-tracy=true
            ztracy.Message(bw.getWritten());

            // Emit into sync_writer stream
            {
                self.sync_writer.mutex.lock();
                defer self.sync_writer.mutex.unlock();

                self.sync_writer.writer.writeAll(bw.getWritten()) catch
                    @panic("Unable to write to event stream");
            }
        }
    };
}

/// Returns a namespace-scoped registry of events. Each event has a
/// corresponding code in the `Tag' enum, which must be registered via the
/// register() method.
pub fn EventRegistry(comptime namespace: []const u8, comptime Tag: type) type {
    assert(@typeInfo(Tag) == .Enum);

    return struct {
        const Self = @This();

        /// Registers an event in this scoped registry. Each event type has a
        /// corresponding level (following std.log.Level) and a user-defined
        /// struct of fields for this event.
        pub fn register(
            comptime code: Tag,
            comptime level: Level,
            comptime User: type,
        ) type {
            assert(@typeInfo(User) == .Struct);

            return struct {
                const code = code;
                const namespace = namespace;
                const level = level;
                pub const User = User;

                timestamp: Timespec,
                user: User,

                /// Constructs an event record at the given timestamp and with
                /// the corresponding `user' data.
                pub fn init(ts: Timespec, user: User) @This() {
                    return @This(){ .timestamp = ts, .user = user };
                }
            };
        }
    };
}

test "event registry" {
    const alloc = std.testing.allocator;
    const SimClock = @import("clock.zig").SimClock;

    const MyScopedRegistry = EventRegistry("my.namespace", enum {
        foo,
    });

    const FooEvent = MyScopedRegistry.register(.foo, .info, struct {
        value1: u64,
    });

    try std.testing.expectEqualStrings("info", FooEvent.level.asText());
    try std.testing.expectEqualStrings("my.namespace", FooEvent.namespace);
    try std.testing.expectEqualStrings("foo", @tagName(FooEvent.code));

    // create a temporary directory for our log output
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("stderr.log", .{ .read = true });
    defer tmp_file.close();

    var tmp_mutex = std.Thread.Mutex{};
    var sync_writer = SyncEventWriter{
        .writer = tmp_file.writer(),
        .mutex = &tmp_mutex,
    };

    var clk = SimClock{};
    clk.setTime(1000);

    var e = Emitter(SimClock).init(.info, sync_writer);
    e.emit(&clk, 0, FooEvent, .{ .value1 = 42 });

    const expect = "           1000 [000] (info)    my.namespace              foo - value1=42 \n";

    try tmp_file.seekTo(0);
    const buf = try tmp_file.reader().readAllAlloc(alloc, expect.len);
    defer alloc.free(buf);

    try std.testing.expectEqualStrings(expect, buf);
}
