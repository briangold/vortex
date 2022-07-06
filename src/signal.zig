//! Signal-handling mechanisms
//!
//! Signals are a pain to work with, but most long-running server applications
//! rely on them to cleanly shutdown or re-load configuration files. The basic
//! design followed here is the "self-pipe trick", where signals are blocked on
//! all threads except for a dedicated signal-handling thread. The signal
//! handler writes a sentinel byte to a non-blocking pipe, and an application
//! thread can then poll/select/etc. on that pipe descriptor.
//!
//! This could be optimized on Linux, where signalfd is available, but for now
//! we've built something that should port well to other POSIX systems.
//!
//! For the user-facing API, see the Vortex.signal namespace in vortex.zig.

const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const Mutex = std.Thread.Mutex;
const Futex = std.Thread.Futex;

const SignalBitSet = std.bit_set.IntegerBitSet(32);
const shutdown = std.math.maxInt(u32);

const is_darwin = builtin.target.isDarwin();

const SignalPipe = struct {
    rd: os.fd_t,
    wr: os.fd_t,

    const magic_byte = ".";

    fn init() !SignalPipe {
        const fds = try std.os.pipe2(os.O.NONBLOCK | os.O.CLOEXEC);
        return SignalPipe{
            .rd = fds[0],
            .wr = fds[1],
        };
    }

    fn deinit(sp: *SignalPipe) void {
        os.close(sp.rd);
        os.close(sp.wr);
    }

    /// Writes sentinel byte into pipe, indicating signal has occurred
    fn write(sp: *const SignalPipe) !void {
        // Write a single byte to the write-end of the pipe. We use a non-
        // blocking pipe and don't care if the pipe gets full. In that
        // case, when the reader catches up, it will get the only information
        // that matters: the signal has arrived. This way the signal handler
        // does not block.
        _ = os.write(sp.wr, magic_byte) catch |err| switch (err) {
            error.WouldBlock => {}, // pipe-full OK
            else => return err,
        };
    }

    /// Returns true if signal observed, false if not
    fn read(sp: *const SignalPipe) !bool {
        var byte: [1]u8 = undefined;
        if (os.read(sp.rd, &byte)) |n| {
            assert(n == 1);
            assert(byte[0] == magic_byte[0]);
            return true;
        } else |err| switch (err) {
            error.WouldBlock => return false,
            else => return err,
        }
    }
};

pub const SupportedSignal = enum(c_int) {
    sighup = os.SIG.HUP,
    sigint = os.SIG.INT,
    sigquit = os.SIG.QUIT,
    sigusr1 = os.SIG.USR1,
    sigusr2 = os.SIG.USR2,
    sigalrm = os.SIG.ALRM,
    sigterm = os.SIG.TERM,

    pub fn format(
        sig: SupportedSignal,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{s}", .{@tagName(sig)});
    }
};

const signal_max = 31;

pub const SignalJunction = struct {
    mask: Atomic(u32),
    observed: Atomic(u32),
    mutex: Mutex,
    handle: std.Thread,

    var global_pipes: [signal_max]?SignalPipe = [_]?SignalPipe{null} ** signal_max;

    pub fn init(st: *SignalJunction) !void {
        // Sanity check: global registry is empty at start
        for (global_pipes) |maybe_gp| assert(maybe_gp == null);

        var sigmask = posix.SignalSet{};
        inline for (std.meta.fields(SupportedSignal)) |sf| {
            const sig = @enumToInt(@field(SupportedSignal, sf.name));
            sigmask.add(sig) catch
                std.debug.panic("Unable to add signal {d}", .{sig});
        }
        posix.sigmask(.block, &sigmask, null) catch |err|
            std.debug.panic("Unable to block signal set: {}", .{err});

        st.* = SignalJunction{
            .mask = Atomic(u32).init(0),
            .observed = Atomic(u32).init(0),
            .mutex = .{},
            .handle = try std.Thread.spawn(
                .{},
                thread_entry,
                .{ &st.mask, &st.observed },
            ),
        };
    }

    pub fn deinit(st: *SignalJunction) void {
        st.mask.store(shutdown, .Monotonic);
        Futex.wake(&st.mask, 1);

        st.handle.join();

        for (global_pipes) |*maybe_gp| {
            if (maybe_gp.*) |*gp| {
                gp.deinit();
                maybe_gp.* = null;
            }
        }
    }

    pub fn register(st: *SignalJunction, sig: SupportedSignal) !os.fd_t {
        st.mutex.lock();
        defer st.mutex.unlock();

        // check that this signal hasn't been registered already
        const signum = @intCast(usize, @enumToInt(sig));
        if (global_pipes[signum]) |gp| return gp.rd;

        var m = SignalBitSet{ .mask = st.mask.load(.Monotonic) };
        assert(!m.isSet(signum));

        // add sig to the registered mask set
        m.set(signum);

        // open pipe as non-blocking, store fd pair in global registry
        global_pipes[signum] = try SignalPipe.init();

        // trigger update
        st.mask.store(m.mask, .Monotonic);
        Futex.wake(&st.mask, 1);

        // Wait for the signal thread to indicate it has processed the mask
        // update. We hold the mutex the whole time for simplicity, on the
        // assumption that signal registration is exceedingly rare and done
        // during startup.
        var thread_observed: u32 = 0;
        while (thread_observed != m.mask) {
            Futex.wait(&st.observed, thread_observed);
            thread_observed = st.observed.load(.Monotonic);
        }

        return global_pipes[signum].?.rd;
    }

    /// Dedicated signal-handling thread. Takes two Futex-compatible locations
    /// to enable lazy registration of signals and an interlock to confirm
    /// when the signal handler has been registered.
    fn thread_entry(mask: *Atomic(u32), observed: *Atomic(u32)) void {
        // Unblock all supported signals and install default signal handler
        var sigmask = posix.SignalSet{};
        inline for (std.meta.fields(SupportedSignal)) |sf| {
            const sig = @enumToInt(@field(SupportedSignal, sf.name));

            sigmask.add(sig) catch
                std.debug.panic("Unable to add signal {d}", .{sig});

            const act = posix.Sigaction{
                .handler = .{ .sigaction = os.SIG.DFL },
                .mask = undefined,
                .flags = undefined,
            };
            posix.sigaction(@intCast(u6, sig), &act, null) catch |err|
                std.debug.panic("Unable to register default handler: {}", .{err});
        }

        posix.sigmask(.unblock, &sigmask, null) catch |err|
            std.debug.panic("Unable to unblock signal set: {}", .{err});

        var prev_mask: u32 = 0;
        while (true) {
            // Wait for a mask change
            Futex.wait(mask, prev_mask);
            const new_mask = mask.load(.Monotonic);

            if (new_mask == shutdown) {
                // Special value (all 1s, guaranteed not a supported mask)
                // indicates the main runtime has requested a shutdown of the
                // signal thread so we can safely join() it.
                return;
            } else {
                // bit mask has changed

                // compute diff
                var diff = SignalBitSet{ .mask = prev_mask };
                diff.toggleAll();
                diff.setIntersection(SignalBitSet{ .mask = new_mask });

                // iterate over set bits in diff, getting index
                var it = diff.iterator(.{});
                while (it.next()) |idx| {
                    // install our custom handler
                    var act = posix.Sigaction{
                        .handler = .{ .handler = sig_handler },
                        .mask = posix.empty_sigset,
                        .flags = 0,
                    };

                    posix.sigaction(@intCast(u6, idx), &act, null) catch
                        @panic("Unable to register signal handler");
                }
            }

            prev_mask = new_mask;

            // Indicate back to the main runtime that we've observed this new
            // mask value and its now safe to handle the requested signal(s).
            observed.store(prev_mask, .Monotonic);
            Futex.wake(observed, 1);
        }
    }

    fn sig_handler(sig: i32) callconv(.C) void {
        const pp = global_pipes[@intCast(usize, sig)] orelse unreachable;
        pp.write() catch |err| std.debug.panic("Signal pipe error: {}", .{err});
    }
};

// NOTE: Signal handling in the current Zig std isn't very mature yet, and
// so this `posix` namespace smooths over the gaps and inconsistencies for
// now.
//
// Issues uncovered:
//   - pthread_sigmask isn't available, and sigprocmask is "undefined" in a
//     multi-threaded environment. So we import pthread_sigmask from libc.
//   - sigaddset isn't exported via std.os, and what is in the linux and darwin
//     platforms isn't idiomatic Zig. So we import sigaddset from libc and
//     wrap it in a struct for better ergonomics.
//   - getpid isn't exported via std.os, and we want to kill(getpid(), sig) to
//     send the signal to the process, rather than raise(sig) which directs
//     to the thread itself. We only use this in testing.

const posix = struct {
    const Sigaction = os.Sigaction;
    const sigaction = os.sigaction;
    const empty_sigset = os.empty_sigset;

    fn sigmask(
        how: enum { block, unblock, setmask },
        set: ?*const SignalSet,
        oldset: ?*SignalSet,
    ) !void {
        const flags: c_int = switch (how) {
            .block => if (!is_darwin) os.SIG.BLOCK else os.SIG._BLOCK,
            .unblock => if (!is_darwin) os.SIG.UNBLOCK else os.SIG._UNBLOCK,
            .setmask => if (!is_darwin) os.SIG.SETMASK else os.SIG._SETMASK,
        };

        const raw_set = if (set) |s| &s.set else null;
        const raw_oldset = if (oldset) |s| &s.set else null;

        return switch (c.pthread_sigmask(flags, raw_set, raw_oldset)) {
            .SUCCESS => {},
            else => |err| os.unexpectedErrno(err),
        };
    }

    const SignalSet = struct {
        set: os.sigset_t = empty_sigset,

        fn add(sset: *SignalSet, signum: c_int) !void {
            if (c.sigaddset(&sset.set, signum) != 0) {
                return error.InvalidSignal;
            }
        }
    };

    const c = struct {
        extern "c" fn pthread_sigmask(
            how: c_int,
            set: ?*const os.sigset_t,
            oldset: ?*os.sigset_t,
        ) std.c.E;

        extern "c" fn sigemptyset(set: *os.sigset_t) c_int;
        extern "c" fn sigaddset(set: *os.sigset_t, signum: c_int) c_int;

        // for testing
        extern "c" fn getpid() c_int;
    };
};

test "sigpipe" {
    var sj: SignalJunction = undefined;
    try sj.init();
    defer sj.deinit();

    const sig = SupportedSignal.sigint;

    // register the signal
    _ = try sj.register(sig);

    // trigger the signal
    try os.kill(posix.c.getpid(), @enumToInt(sig));

    // observe the signal
    const signum = @intCast(usize, @enumToInt(sig));
    while (!(try SignalJunction.global_pipes[signum].?.read())) {}
}
