const std = @import("std");
const panic = std.debug.panic;
const target = @import("builtin").target;

// Nanosecond-resolution 63-bit timers give us operation for 584 years before
// overflow. We use a u63 for compatibility with the signed 64-bit nsec value
// in std.os.timespec
pub const Timespec = u63;
pub const max_time = std.math.maxInt(Timespec);

pub const DefaultClock = struct {
    /// Sample a high-precision monotonic clock that tracks time even while the
    /// OS is suspended/sleeping. The returned value should not be used for
    /// deriving human-readable wall-clock times. It's useful for measuring
    /// forward progress and describing timeouts.
    pub fn now(_: *DefaultClock) Timespec {
        // Guard against various bugs beyond our control, e.g.
        // https://bugzilla.redhat.com/show_bug.cgi?id=448449
        // (credit to Joran Dirk Greef in TigerBeetle for this idea and reference)
        const Guard = struct {
            // Use a threadlocal for the guard so we don't need atomic ops when
            // updating it below.
            threadlocal var val: Timespec = 0;
        };

        // References for porting to other platforms:
        //  Clang libcxx std::chrono::steady_clock - https://github.com/llvm/llvm-project/blob/main/libcxx/src/chrono.cpp
        //  TigerBeetle time.zig - https://github.com/coilhq/tigerbeetle/blob/main/src/time.zig

        const t = switch (target.os.tag) {
            // see https://github.com/ziglang/zig/pull/933#discussion_r656021295
            .linux => clock_gettime_ns(std.os.CLOCK.BOOTTIME),

            // see https://opensource.apple.com/source/Libc/Libc-1439.40.11/gen/clock_gettime.c.auto.html
            .macos, .tvos, .watchos, .ios => clock_gettime_ns(std.os.CLOCK.MONOTONIC_RAW),

            else => @compileError("unsupported platform"),
        };

        if (t < Guard.val) @panic("monotonic clock went backwards");
        Guard.val = t;

        return t;
    }

    fn clock_gettime_ns(clk_id: i32) Timespec {
        var ts: std.os.timespec = undefined;
        std.os.clock_gettime(clk_id, &ts) catch |err| {
            panic("clock_gettime({d}) failed: {s}", .{ clk_id, @errorName(err) });
        };

        var ns: Timespec = 0;
        ns += @intCast(Timespec, ts.tv_sec) * std.time.ns_per_s;
        ns += @intCast(Timespec, ts.tv_nsec);
        return ns;
    }
};

pub const SimClock = struct {
    prev: Timespec = 0,

    pub fn now(self: *SimClock) Timespec {
        // An SimClock (used in testing) is advanced in the I/O engine via
        // setTime(), and calls to now() see the previous time until the next
        // event is processed.
        return self.prev;
    }

    /// Set the time
    pub fn setTime(self: *SimClock, to: Timespec) void {
        self.prev = to;
    }
};
