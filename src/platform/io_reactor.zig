const std = @import("std");
const target = @import("builtin").target;
const assert = std.debug.assert;

const Timespec = @import("../clock.zig").Timespec;
const Emitter = @import("../event.zig").Emitter;
const EventRegistry = @import("../event.zig").EventRegistry;
const CancelToken = @import("../scheduler.zig").CancelToken;
const FwdIndexedList = @import("../list.zig").FwdIndexedList;
const CancelQueue = @import("cancel_queue.zig").CancelQueue;
const OsDescriptor = std.os.fd_t;
const max_time = @import("../clock.zig").max_time;
const threadId = @import("../runtime.zig").threadId;

const Poller = switch (target.os.tag) {
    .linux => EpollPoller,
    .macos, .tvos, .watchos, .ios => KqueuePoller,

    else => @compileError("unsupported platform"),
};

const Index = u32; // indexes events in internal lists

pub fn ReactorPlatform(comptime Scheduler: type) type {
    const Entry = struct {
        next: ?Index = null, // primary linkage (free list, per-fd, etc.)
        next_to: ?Index = null, // used by timewheel ordering

        timeout: Timespec = undefined,
        op: *anyopaque = undefined, // TODO: document further

        fn getOp(entry: *@This(), comptime Op: type) *Op {
            return @ptrCast(
                *Op,
                @alignCast(@alignOf(Op), entry.op),
            );
        }
    };

    return struct {
        pub const Config = struct {
            /// Maximum outstanding I/O requests that can be submitted. Must be
            /// a power-of-2 (enforced at startup).
            max_events: Index = 128,

            /// Limit on how many requests can be polled at once. Must be less
            /// than or equal to max_events (enforced at startup).
            max_poll_events: Index = 128,

            /// How many slots (hash buckets) in the timewheel. More slots mean
            /// generally shorter searches when identifying timeouts, but also
            /// more memory required. Must be power-of-2 (enforced at startup).
            timewheel_slots: usize = 128,

            /// Resolution (nanoseconds) of each timewheel slot. Finer
            /// resolution (smaller values) mean more slots get used for
            /// timeouts in a given range. This can have positive and negative
            /// effects: fewer entries in a slot is generally better, as we
            /// store entries unsorted and need to search the entire slot. But
            /// more slots mean more places to look, and because entries in a
            /// slot are unsorted, we may encounter more entries from future
            /// times that slow down the search.
            timewheel_resolution: usize = 1024,

            /// Max open file descriptors. Must be power-of-2 (enforced at
            /// startup).
            max_fd: usize = 1024,
        };

        pub const Descriptor = OsDescriptor;
        pub const Scheduler = Scheduler;
        const Clock = Scheduler.Clock;

        const Platform = @This();

        const OpList = FwdIndexedList(Entry, .next);
        const TimeWheel = TimeWheelImpl(Entry, .next_to);
        const FileDescriptorTable = FileDescriptorTableImpl(Entry, .next);
        const IoOperation = IoOperationImpl(Platform);
        const IoStatus = enum {
            invalid,
            success,
            timeout,
            canceled,

            pub fn format(
                status: IoStatus,
                comptime _: []const u8,
                _: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                try writer.print("{s}", .{@tagName(status)});
            }
        };

        clock: *Clock,
        sched: *Scheduler,
        emitter: *Emitter,
        pending: usize,
        entries: []Entry,
        free: OpList,
        fdt: FileDescriptorTable,
        timers: TimeWheel,
        prevTime: Timespec,
        poller: Poller,
        events: []Poller.Event,
        cancelq: CancelQueue(IoOperation, "cancel_next"),

        pub const InitError = anyerror; // TODO: more precise

        pub fn init(
            alloc: std.mem.Allocator,
            config: Config,
            sched: *Scheduler,
            emitter: *Emitter,
        ) InitError!Platform {
            // TODO: check that Index fits based on max_events
            assert(std.math.isPowerOfTwo(config.max_events));
            assert(config.max_poll_events <= config.max_events);

            const entries = try alloc.alloc(Entry, config.max_events);

            var platform = Platform{
                .sched = sched,
                .emitter = emitter,
                .clock = sched.clock,
                .pending = 0,
                .entries = entries,
                .free = OpList.init(entries),
                .fdt = try FileDescriptorTable.init(
                    alloc,
                    entries,
                    config.max_fd,
                ),
                .timers = try TimeWheel.init(
                    alloc,
                    entries,
                    config.timewheel_slots,
                    config.timewheel_resolution,
                ),
                .prevTime = 0,
                .poller = try Poller.init(),
                .events = try alloc.alloc(Poller.Event, config.max_poll_events),
                .cancelq = .{},
            };

            var idx: Index = 0;
            while (idx < config.max_events) : (idx += 1) {
                platform.free.push(idx);
            }

            return platform;
        }

        pub fn deinit(platform: *Platform, alloc: std.mem.Allocator) void {
            platform.fdt.deinit(alloc);
            platform.timers.deinit(alloc);
            platform.poller.deinit();

            alloc.free(platform.events);
            alloc.free(platform.entries);
        }

        /// Polls for event completions, triggering the registered wakeup
        /// callback (typically to reschedule a task for continued execution).
        /// Waits up to `timeout' nanoseconds for a completion. Returns the
        /// number of completions handled.
        pub fn poll(platform: *Platform, timeout_ns: Timespec) !usize {
            var count: usize = 0;

            // Process expired timeouts
            const now = platform.clock.now();
            defer platform.prevTime = now; // set up for next call to enter()

            var expired = platform.timers.expireTimeouts(.{ platform.prevTime, now });
            while (expired.pop()) |idx| {
                const entry = &platform.entries[idx];

                // remove the expired entry from FDT list and wake callback
                const op = entry.getOp(IoOperation);
                if (op.descriptor()) |fd| {
                    _ = platform.fdt.cancelEntry(
                        idx,
                        fd,
                    ) orelse @panic("No fdt entry to expire");
                }

                count += platform.wakeupEntry(idx, .timeout);
            }

            // Process pending cancellations, if any
            var to_cancel = platform.cancelq.unlink();
            while (to_cancel.get()) |op| : (_ = to_cancel.next()) {
                if (op.descriptor()) |fd| {
                    platform.emitEvent(IoCancelEvent, .{ .op = op });

                    // remove any file-descriptor tracking entries
                    _ = platform.fdt.cancelEntry(op.idx, fd) orelse
                        @panic("No fdt entry to cancel");
                }

                // Remove the timeout. If not found, then the entry has already
                // been woken up and removed, so there's nothing more to do here.
                if (platform.timers.unregTimeout(op.idx)) |removed| {
                    _ = removed;

                    // wakeup the handler and free the entry
                    count += platform.wakeupEntry(op.idx, .canceled);
                }
            }

            // if we haven't processed any ops to this point, poll
            if (count == 0) {
                var nevents = try platform.poller.poll(platform.events, timeout_ns);

                for (platform.events[0..nevents]) |*ev| {
                    const fd = ev.descriptor();
                    const kind = ev.readiness();

                    var ops = platform.fdt.getEntries(fd, kind);

                    while (ops.pop()) |idx| {
                        // remove the timeout that was set for this entry and
                        // wake callback
                        _ = platform.timers.unregTimeout(idx);
                        count += platform.wakeupEntry(idx, .success);
                    }
                }
            }

            return count;
        }

        fn wakeupEntry(platform: *Platform, idx: Index, status: IoStatus) usize {
            const entry = &platform.entries[idx];

            const op = entry.getOp(IoOperation);
            platform.emitEvent(IoWakeEvent, .{ .op = op, .status = status });

            op.completion.status = status;
            op.completion.callback(
                op.completion.callback_ctx,
                op.completion.callback_data,
            );

            entry.op = undefined;
            platform.free.push(idx);

            platform.pending -= 1;

            return 1;
        }

        pub fn hasPending(platform: *Platform) bool {
            return platform.pending != 0;
        }

        fn emitEvent(
            platform: *Platform,
            comptime Event: type,
            user: Event.User,
        ) void {
            platform.emitter.emit(platform.clock.now(), threadId(), Event, user);
        }

        const posix = @import("posix_sockets.zig");

        // override socket() with nonblocking flag
        pub fn socket(
            _: *Platform,
            domain: u32,
            socket_type: u32,
            protocol: u32,
        ) std.os.SocketError!std.os.socket_t {
            return std.os.socket(
                domain,
                socket_type | std.os.SOCK.NONBLOCK,
                protocol,
            );
        }

        // non-async functions
        pub const close = posix.close;
        pub const bind = posix.bind;
        pub const listen = posix.listen;
        pub const getsockname = posix.getsockname;
        pub const getpeername = posix.getpeername;
        pub const setsockopt = posix.setsockopt;
        pub const getsockopt = posix.getsockopt;

        pub fn accept(
            platform: *Platform,
            listen_fd: Descriptor,
            addr: *std.os.sockaddr,
            addrlen: *std.os.socklen_t,
            flags: u32,
            timeout: Timespec,
        ) !Descriptor {
            while (true) {
                var op = IoOperation{
                    .platform = platform,
                    .args = .{ .accept = .{ .listen_fd = listen_fd } },
                };

                const res = std.os.accept(
                    listen_fd,
                    addr,
                    addrlen,
                    flags | std.os.SOCK.NONBLOCK,
                );

                if (res) |fd| {
                    return @intCast(Descriptor, fd);
                } else |err| switch (err) {
                    error.WouldBlock => {
                        try platform.wait(&op, timeout);
                    },
                    else => return err,
                }
            }
        }

        pub fn connect(
            platform: *Platform,
            fd: Descriptor,
            addr: *std.os.sockaddr,
            addrlen: std.os.socklen_t,
            timeout: Timespec,
        ) !Descriptor {
            var op = IoOperation{
                .platform = platform,
                .args = .{ .connect = .{ .fd = fd } },
            };

            _ = std.os.connect(fd, addr, addrlen) catch |err| switch (err) {
                error.WouldBlock => {
                    try platform.wait(&op, timeout);
                },
                else => return err,
            };

            // check for connection errors
            try std.os.getsockoptError(fd);

            return fd;
        }

        pub fn recv(
            platform: *Platform,
            fd: Descriptor,
            buffer: []u8,
            flags: u32,
            timeout: Timespec,
        ) !usize {
            while (true) {
                var op = IoOperation{
                    .platform = platform,
                    .args = .{ .recv = .{ .fd = fd } },
                };

                const res = std.os.recv(fd, buffer, flags);

                if (res) |count| {
                    return count;
                } else |err| switch (err) {
                    error.WouldBlock => {
                        try platform.wait(&op, timeout);
                    },
                    else => return err,
                }
            }
        }

        pub fn send(
            platform: *Platform,
            fd: Descriptor,
            buffer: []const u8,
            flags: u32,
            timeout: Timespec,
        ) !usize {
            while (true) {
                var op = IoOperation{
                    .platform = platform,
                    .args = .{ .send = .{ .fd = fd } },
                };

                const res = std.os.send(fd, buffer, flags);

                if (res) |count| {
                    return count;
                } else |err| switch (err) {
                    error.WouldBlock => {
                        try platform.wait(&op, timeout);
                    },
                    else => return err,
                }
            }
        }

        fn wait(
            platform: *Platform,
            op: *IoOperation,
            timeout: Timespec,
        ) !void {
            try platform.sched.suspendTask(timeout, op);

            return switch (op.completion.status) {
                .invalid => unreachable,
                .canceled, .timeout => error.IoCanceled,
                .success => {},
            };
        }

        pub fn sleep(platform: *Platform, interval: Timespec) !void {
            var op = IoOperation{
                .platform = platform,
                .args = .sleep,
            };
            try platform.sched.suspendTask(interval, &op);
        }

        /// Implements the I/O loop operations for a Futex. See the platform-
        /// independent Futex library for more information.
        pub const FutexEvent = struct {
            op: IoOperation,

            pub fn init(platform: *Platform) FutexEvent {
                return FutexEvent{
                    .op = IoOperation{
                        .platform = platform,
                        .args = .{ .futex_wait = .{
                            .state = .{ .value = .empty },
                        } },
                    },
                };
            }

            /// Waits for a wakeup event (no error) or the timeout to expire.
            pub fn wait(tl: *FutexEvent, maybe_timeout: ?Timespec) !void {
                const timeout = maybe_timeout orelse max_time;
                try tl.op.platform.sched.suspendTask(timeout, &tl.op);

                return switch (tl.op.completion.status) {
                    .success => unreachable,
                    .timeout => error.FutexTimeout,
                    .canceled => {}, // we canceled the timeout = success
                    .invalid => unreachable,
                };
            }

            /// Notifies the wait-half of this event
            pub fn notify(tl: *FutexEvent) void {
                const state = &tl.op.args.futex_wait.state;

                // state transition loop - atomically transition:
                //   empty   => notified :: the waiter will see notified
                //   waiting => _        :: notify the waiter
                while (true) {
                    switch (state.load(.Acquire)) {
                        // The notification arrives before the waiter
                        .empty => {
                            if (state.tryCompareAndSwap(
                                .empty,
                                .notified,
                                .Release,
                                .Monotonic,
                            ) == null) {
                                return;
                            }
                            // CAS failure - retry
                        },

                        // The waiter arrived first, so remove its timeout
                        .waiting => {
                            // Update the state. In the rare case where a waiter
                            // observes that it has been removed from the
                            // WaitQueue, this state update ensures the 2nd,
                            // indefinite wait doesn't block.
                            state.store(.notified, .Release);

                            // Cancel the timeout and wake the callback
                            tl.op.cancel();

                            return;
                        },

                        // Double-notify cannot happen
                        .notified => unreachable,
                    }
                }
            }
        };

        const ScopedRegistry = EventRegistry("vx.io", enum {
            io_suspend,
            io_wake,
            io_cancel,
        });
        const IoSuspendEvent = ScopedRegistry.register(.io_suspend, .debug, struct {
            op: *IoOperation,
        });
        const IoWakeEvent = ScopedRegistry.register(.io_wake, .debug, struct {
            op: *IoOperation,
            status: IoStatus,
        });
        const IoCancelEvent = ScopedRegistry.register(.io_cancel, .debug, struct {
            op: *IoOperation,
        });
    };
}

const EpollPoller = struct {
    const Descriptor = OsDescriptor;
    const OsEvent = std.os.system.epoll_event;

    pollq: Descriptor,

    const InitError = std.os.EpollCreateError;

    pub fn init() InitError!Poller {
        return Poller{
            .pollq = try std.os.epoll_create1(0),
        };
    }

    pub fn deinit(poller: *Poller) void {
        assert(poller.pollq > 0);
        std.os.close(poller.pollq);
        poller.pollq = -1;
    }

    pub const PollError = error{};

    pub fn poll(
        poller: *Poller,
        events: []Event,
        timeout_ns: usize,
    ) PollError!usize {
        const timeout_ms = @intCast(i32, timeout_ns / std.time.ns_per_ms);

        return std.os.epoll_wait(
            poller.pollq,
            Event.toOsSlice(events),
            timeout_ms,
        );
    }

    const CtlOp = enum { add, del };

    pub const RegisterError = std.os.EpollCtlError;

    pub fn register(poller: *Poller, fd: Descriptor) RegisterError!void {
        return poller.ctl(.add, fd);
    }

    pub const UnregisterError = std.os.EpollCtlError;

    pub fn unregister(poller: *Poller, fd: Descriptor) UnregisterError!void {
        return poller.ctl(.del, fd);
    }

    fn ctl(
        poller: *Poller,
        comptime ctlop: CtlOp,
        fd: Descriptor,
    ) !void {
        const epoll = std.os.system.EPOLL;

        const op = switch (ctlop) {
            .add => epoll.CTL_ADD,
            .del => epoll.CTL_DEL,
        };

        var event = OsEvent{
            .events = epoll.IN | epoll.OUT | epoll.ET,
            .data = .{ .fd = fd },
        };

        return std.os.epoll_ctl(poller.pollq, op, fd, &event);
    }

    const Event = struct {
        event: OsEvent,

        pub fn readiness(ev: Event) Readiness {
            const rd = (ev.event.events & std.os.system.EPOLL.IN) != 0;
            const wr = (ev.event.events & std.os.system.EPOLL.OUT) != 0;

            if (rd and wr) return .rdwr;
            if (rd) return .rd;
            if (wr) return .wr;
            return .none;
        }

        pub fn descriptor(ev: Event) Descriptor {
            return @intCast(Descriptor, ev.event.data.fd);
        }

        fn toOsSlice(events: []Event) []OsEvent {
            comptime {
                const fields = std.meta.fields(Event);
                assert(fields.len == 1);
                assert(fields[0].field_type == OsEvent);
            }

            // This cast is safe b/c--as the above comptime block verifies--the
            // only field in this Event struct is an os.system.epoll_event
            return @ptrCast([*]OsEvent, events)[0..events.len];
        }
    };
};

const KqueuePoller = struct {
    const Descriptor = OsDescriptor;
    const OsEvent = std.os.Kevent;

    const EVFILT_READ = std.os.system.EVFILT_READ;
    const EVFILT_WRITE = std.os.system.EVFILT_WRITE;

    pollq: Descriptor,

    pub const InitError = std.os.KQueueError;

    pub fn init() !Poller {
        return Poller{
            .pollq = try std.os.kqueue(),
        };
    }

    pub fn deinit(poller: *Poller) void {
        assert(poller.pollq > 0);
        std.os.close(poller.pollq);
        poller.pollq = -1;
    }

    pub const PollError = std.os.KEventError;

    pub fn poll(
        poller: *Poller,
        events: []Event,
        timeout_ns: usize,
    ) PollError!usize {
        const TsNs = std.meta.fieldInfo(std.os.timespec, .tv_nsec).field_type;
        const TsS = std.meta.fieldInfo(std.os.timespec, .tv_sec).field_type;

        const ts = std.os.timespec{
            .tv_nsec = @intCast(TsNs, timeout_ns % std.time.ns_per_s),
            .tv_sec = @intCast(TsS, timeout_ns / std.time.ns_per_s),
        };

        return std.os.kevent(
            poller.pollq,
            &[0]OsEvent{},
            Event.toOsSlice(events),
            &ts,
        );
    }

    const CtlOp = enum { add, del };

    pub const RegisterError = std.os.KEventError;

    pub fn register(poller: *Poller, fd: Descriptor) !void {
        return poller.ctl(.add, fd);
    }

    pub const UnregisterError = std.os.KEventError;

    pub fn unregister(poller: *Poller, fd: Descriptor) !void {
        return poller.ctl(.del, fd);
    }

    fn ctl(
        poller: *Poller,
        comptime ctlop: CtlOp,
        fd: Descriptor,
    ) !void {
        const flags: usize = switch (ctlop) {
            .add => (std.os.system.EV_ADD | std.os.system.EV_CLEAR),
            .del => std.os.system.EV_DELETE,
        };

        var changes = [_]Event{
            Event.init(fd, EVFILT_READ, flags),
            Event.init(fd, EVFILT_WRITE, flags),
        };

        _ = try std.os.kevent(
            poller.pollq,
            Event.toOsSlice(&changes),
            &[0]OsEvent{},
            null,
        );
    }

    const Event = struct {
        event: OsEvent,

        pub fn init(
            fd: Descriptor,
            comptime filter: comptime_int,
            comptime flags: comptime_int,
        ) Event {
            const Ident = std.meta.fieldInfo(OsEvent, .ident).field_type;
            return Event{ .event = .{
                .ident = @intCast(Ident, fd),
                .filter = filter,
                .flags = flags,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            } };
        }

        pub fn readiness(ev: Event) Readiness {
            const Filter = std.meta.fieldInfo(OsEvent, .filter).field_type;
            if (ev.event.filter == @as(Filter, EVFILT_READ)) {
                return .rd;
            } else if (ev.event.filter == @as(Filter, EVFILT_WRITE)) {
                return .wr;
            } else {
                @panic("unknown event filter");
            }
        }

        pub fn descriptor(ev: Event) Descriptor {
            return @intCast(Descriptor, ev.event.ident);
        }

        fn toOsSlice(events: []Event) []OsEvent {
            comptime {
                const fields = std.meta.fields(Event);
                assert(fields.len == 1);
                assert(fields[0].field_type == OsEvent);
            }

            // This cast is safe because--as the above comptime block verifies--the
            // only field in this Event struct is an OsEvent
            return @ptrCast([*]OsEvent, events)[0..events.len];
        }
    };
};

fn IoOperationImpl(comptime Platform: type) type {
    return struct {
        const IoOperation = @This();

        const IoCompletion = struct {
            status: Platform.IoStatus,
            callback: fn (*anyopaque, usize) void,
            callback_ctx: *anyopaque,
            callback_data: usize,
        };

        const Descriptor = Platform.Descriptor;

        platform: *Platform,

        idx: Index = undefined,
        completion: IoCompletion = undefined,
        cancel_next: ?*IoOperation = null, // cancel queue linkage
        args: union(enum) {
            sleep,
            futex_wait: struct {
                const State = enum(u8) { empty, waiting, notified };
                state: std.atomic.Atomic(State),
            },
            accept: struct {
                listen_fd: Descriptor,
            },
            connect: struct {
                fd: Descriptor,
            },
            recv: struct {
                fd: Descriptor,
            },
            send: struct {
                fd: Descriptor,
            },
        },

        fn descriptor(op: *const IoOperation) ?Descriptor {
            return switch (op.args) {
                .sleep, .futex_wait => null,
                .accept => |args| args.listen_fd,
                .connect => |args| args.fd,
                .recv => |args| args.fd,
                .send => |args| args.fd,
            };
        }

        pub fn prep(
            op: *IoOperation,
            timeout: Timespec,
            comptime callback: anytype,
            callback_ctx: anytype,
            callback_data: usize,
        ) !void {
            const idx = op.platform.free.pop() orelse unreachable; // TODO: error return?
            op.idx = idx;

            var entry = &op.platform.entries[idx];
            entry.op = op;

            // convert timeout to absolute time
            const abs_timeout = if (timeout != max_time)
                op.platform.clock.now() + timeout
            else
                timeout;

            entry.timeout = abs_timeout;

            op.completion = IoCompletion{
                .status = .invalid,
                .callback = callback,
                .callback_ctx = callback_ctx,
                .callback_data = callback_data,
            };

            op.platform.pending += 1;
            op.platform.timers.regTimeout(idx);

            const rdy = switch (op.args) {
                .sleep, .futex_wait => Readiness.none,
                .accept, .recv => Readiness.rd,
                .connect, .send => Readiness.wr,
            };

            switch (op.args) {
                .sleep => {},

                .futex_wait => |*args| {
                    // state transition loop - atomically transition:
                    //   empty    => waiting  :: the waker will see waiting
                    //   notified => _        :: already notified, so cancel
                    while (true) {
                        switch (args.state.load(.Acquire)) {
                            // common case
                            .empty => {
                                if (args.state.tryCompareAndSwap(
                                    .empty,
                                    .waiting,
                                    .Release,
                                    .Monotonic,
                                ) == null) {
                                    return;
                                }
                                // CAS failure - retry
                            },

                            // rare: race with waker, we re-wait indefinitely
                            // (see Futex.wait())
                            .waiting => return,

                            // notification already arrived, remove timeout
                            .notified => {
                                // Cancel the timeout and wake the callback
                                op.cancel();

                                return;
                            },
                        }
                    }
                },

                .accept, .connect, .send, .recv => {
                    const fd = op.descriptor() orelse unreachable;
                    if (op.platform.fdt.submitEntry(idx, fd, rdy)) {
                        // lazily add new fd's to poller
                        try op.platform.poller.register(fd);
                    }
                },
            }

            op.platform.emitEvent(Platform.IoSuspendEvent, .{ .op = op });
        }

        fn cancel(op: *IoOperation) void {
            op.platform.cancelq.insert(op);
        }

        pub fn cancelToken(op: *IoOperation) CancelToken {
            return CancelToken.init(op, cancel);
        }

        pub fn format(
            op: *const IoOperation,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            const entry = &op.platform.entries[op.idx];

            try writer.print("{s}", .{@tagName(op.args)});
            try writer.print(" idx={d}", .{op.idx});

            if (op.descriptor()) |fd| {
                try writer.print(" fd={d}", .{fd});
            }

            if (entry.timeout == max_time) {
                try writer.writeAll(" deadline=inf");
            } else {
                try writer.print(" deadline={d}", .{entry.timeout});
            }
        }
    };
}

fn TimeWheelImpl(
    comptime OpEntry: anytype,
    comptime link_field: std.meta.FieldEnum(OpEntry),
) type {
    return struct {
        const TimeWheel = @This();

        const Descriptor = OsDescriptor;
        const TimerList = FwdIndexedList(OpEntry, link_field);

        entries: []OpEntry,
        slots: []TimerList,
        slot_shift: u6,

        pub fn init(
            alloc: std.mem.Allocator,
            entries: []OpEntry,
            num_slots: usize,
            slot_resolution: usize,
        ) !TimeWheel {
            assert(std.math.isPowerOfTwo(num_slots));
            assert(std.math.isPowerOfTwo(slot_resolution));

            var tw = TimeWheel{
                .entries = entries,
                .slots = try alloc.alloc(TimerList, num_slots),
                .slot_shift = @intCast(u6, std.math.log2(slot_resolution)),
            };

            for (tw.slots) |*slot| slot.* = TimerList.init(entries);

            return tw;
        }

        pub fn deinit(tw: *TimeWheel, alloc: std.mem.Allocator) void {
            alloc.free(tw.slots);
        }

        /// Insert a new timeout linkage based on the entry in idx.
        /// NOTE: assumes the entry already has its timeout field set
        pub fn regTimeout(tw: *TimeWheel, idx: Index) void {
            const to = tw.entries[idx].timeout;

            // append entry into timewheel slot
            tw.slots[tw.getSlotIndex(to)].push(idx);
        }

        /// Delete the timeout linkage for entry at `idx'. Returns the timeout
        /// value that was removed, or null if it wasn't found.
        pub fn unregTimeout(tw: *TimeWheel, idx: Index) ?Timespec {
            const to = tw.entries[idx].timeout;

            // Because we use a singly-linked (forward) list for each slot,
            // we have to iterate from the slot head until we find the matching
            // entry to remove. This should perform OK provided we have fairly
            // short TimeLists, i.e. enough slots and even distribution across.
            const slot = &tw.slots[tw.getSlotIndex(to)];

            if (slot.unlink(idx)) return to;

            return null;
        }

        /// Find timeouts in the range (range.0, range.1], and move them
        /// from the timer wheel onto the returned list.
        pub fn expireTimeouts(tw: *TimeWheel, range: [2]Timespec) TimerList {
            const start = tw.getSlotIndex(range[0]);
            const count = std.math.min(
                tw.getSlotDelta(range),
                tw.slots.len,
            );
            assert(count >= 1);

            var list = TimerList.init(tw.entries);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const idx = (start + i) % tw.slots.len;
                const slot = &tw.slots[idx];

                var it = slot.iter();
                while (it.get()) |elem_idx| {
                    const e = &tw.entries[elem_idx];
                    if (e.timeout > range[0] and e.timeout <= range[1]) {
                        // unlink from the slot, advance the iterator
                        _ = slot.delete(&it) orelse unreachable;

                        // link into the return list
                        list.push(elem_idx);
                    } else {
                        _ = it.next(); // advance the iterator
                    }
                }
            }

            return list;
        }

        /// Find the next timeout in chronological order from `after'
        /// Note: this is expensive as we store timers in unsorted lists
        /// and are thus forced to scan all timers. Only call this in
        /// specialized scenarios such as when simulating time with an
        /// autojump clock.
        pub fn nextTimeout(tw: *const TimeWheel, after: Timespec) ?Timespec {
            var min_timeout: ?Timespec = null;
            var idx: usize = 0;
            while (idx < tw.slots.len) : (idx += 1) {
                const slot = &tw.slots[idx];

                var it = slot.iter();
                while (it.get()) |elem_idx| : (_ = it.next()) {
                    const entry_timeout = tw.entries[elem_idx].timeout;
                    if (entry_timeout <= after) continue;

                    if (min_timeout == null or entry_timeout < min_timeout.?) {
                        min_timeout = entry_timeout;
                    }
                }
            }

            return min_timeout;
        }

        fn getSlotIndex(tw: *TimeWheel, val: Timespec) usize {
            // We divide timespec into three contiguous bit ranges:
            //  - lower (least-significant): truncated by slot_resolution
            //  - middle: maps to the slot in the timewheel
            //  - upper: remaining bits of timespec for matching
            return (val >> tw.slot_shift) % tw.slots.len;
        }

        fn getSlotDelta(tw: *TimeWheel, range: [2]Timespec) usize {
            assert(range[1] >= range[0]);
            const upper = (range[1] >> tw.slot_shift);
            const lower = (range[0] >> tw.slot_shift);
            return upper - lower + 1;
        }
    };
}

test "timewheel" {
    const alloc = std.testing.allocator;

    const TestOpEntry = struct {
        timeout: Timespec = 0,
        next: ?usize = null,
    };

    const TestWheel = TimeWheelImpl(TestOpEntry, .next);
    var entries = [_]TestOpEntry{.{} ** 4};

    var tw = try TestWheel.init(alloc, &entries, 8, 1024);
    defer tw.deinit(alloc);

    entries[0].timeout = 1025;
    tw.regTimeout(0);

    try std.testing.expect(tw.nextTimeout(0).? == 1025);
    try std.testing.expect(tw.nextTimeout(1025) == null);

    const tl = tw.expireTimeouts(.{ 0, 1025 });
    var it = tl.iter();
    try std.testing.expectEqual(
        @as(Timespec, 1025),
        entries[it.get().?].timeout,
    );
    try std.testing.expect(it.next() == null);

    tw.regTimeout(0);
    try std.testing.expect(tw.unregTimeout(0).? == 1025);
}

fn FileDescriptorTableImpl(
    comptime Entry: anytype,
    comptime link_field: std.meta.FieldEnum(Entry),
) type {
    return struct {
        const FileDescriptorTable = @This();

        const Descriptor = OsDescriptor;
        const List = FwdIndexedList(Entry, link_field);

        entries: []Entry,
        fdt: []DescriptorEntry,
        pending: usize,

        const DescriptorEntry = struct {
            tracked: bool,
            rdlist: List,
            wrlist: List,
        };

        pub fn init(
            alloc: std.mem.Allocator,
            entries: []Entry,
            max_fd: usize,
        ) !FileDescriptorTable {
            assert(std.math.isPowerOfTwo(max_fd));

            var fdt = FileDescriptorTable{
                .entries = entries,
                .fdt = try alloc.alloc(DescriptorEntry, max_fd),
                .pending = 0,
            };

            for (fdt.fdt) |*fde| fde.* = DescriptorEntry{
                .tracked = false,
                .rdlist = List.init(entries),
                .wrlist = List.init(entries),
            };

            return fdt;
        }

        pub fn deinit(
            fdt: *FileDescriptorTable,
            alloc: std.mem.Allocator,
        ) void {
            alloc.free(fdt.fdt);
        }

        /// Submits a new operation entry from slot idx in the borrowed entries
        /// slice.
        pub fn submitEntry(
            fdt: *FileDescriptorTable,
            idx: Index,
            fd: Descriptor,
            kind: Readiness,
        ) bool {
            var fde = &fdt.fdt[@intCast(usize, fd)];

            switch (kind) {
                .rd => fde.rdlist.push(idx),
                .wr => fde.wrlist.push(idx),
                .none => @panic("op cannot require 'no' readiness"),
                .rdwr => @panic("op cannot require read and write readiness"),
            }

            fdt.pending += 1;

            if (!fde.tracked) {
                fde.tracked = true;
                return true;
            }

            return false;
        }

        /// Cancels a previously submitted entry from slot `idx' by removing
        /// it from the pending list. If the entry is not found we return
        /// null; otherwise `idx' is returned. Called by the reactor thread
        /// when processing timeouts, and from a worker thread when cancelling
        /// a task.
        pub fn cancelEntry(
            fdt: *FileDescriptorTable,
            idx: Index,
            fd: Descriptor,
        ) ?Index {
            var fde = &fdt.fdt[@intCast(usize, fd)];
            const lists = [_]*List{ &fde.rdlist, &fde.wrlist };

            for (lists) |list| {
                if (list.unlink(idx)) return idx;
            }

            return null;
        }

        /// Removes and returns any pending entries that were waiting for
        /// `kind' readiness.
        pub fn getEntries(
            fdt: *FileDescriptorTable,
            fd: Descriptor,
            kind: Readiness,
        ) List {
            var fde = &fdt.fdt[@intCast(usize, fd)];

            // Find and remove all entries matching our readiness kind
            var empty = List.init(fdt.entries);
            const lists = switch (kind) {
                .rd => [_]*List{ &fde.rdlist, &empty },
                .wr => [_]*List{ &fde.wrlist, &empty },
                .rdwr => [_]*List{ &fde.rdlist, &fde.wrlist },
                .none => @panic("getEntries() called with 'none' readiness"),
            };

            var ret = List.init(fdt.entries);
            for (lists) |list| {
                var it = list.iter();
                while (it.get()) |idx| {
                    // NOTE: delete advances iterator
                    _ = list.delete(&it) orelse unreachable;
                    ret.push(idx);
                    fdt.pending -= 1;
                }
            }

            return ret;
        }
    };
}

test "fdt" {
    const alloc = std.testing.allocator;

    const TestEntry = struct {
        next: ?usize = null,
    };

    const TestFDT = FileDescriptorTableImpl(TestEntry, .next);

    var entries = [_]TestEntry{.{} ** 4};
    var fdt = try TestFDT.init(alloc, &entries, 64);
    defer fdt.deinit(alloc);

    // submit an op should return true for new fd
    try std.testing.expectEqual(true, fdt.submitEntry(0, 42, .rd));

    // there should be one outstanding op
    try std.testing.expectEqual(@as(usize, 1), fdt.pending);

    // add readiness should return entry
    try std.testing.expect(fdt.getEntries(42, .rd).peek().? == 0);

    // there should be no outstanding entries
    try std.testing.expectEqual(@as(usize, 0), fdt.pending);

    // re-add readiness should return nothing (already removed)
    try std.testing.expect(fdt.getEntries(42, .rd).peek() == null);

    // submit on known fd should return false
    try std.testing.expectEqual(false, fdt.submitEntry(0, 42, .rd));

    // re-add readiness should return entry
    try std.testing.expect(fdt.getEntries(42, .rd).peek().? == 0);

    // submit on known fd should return false
    try std.testing.expectEqual(false, fdt.submitEntry(0, 42, .rd));

    // canceling a pending operation should return its index
    try std.testing.expect(fdt.cancelEntry(0, 42).? == 0);

    // canceling an operation that doesn't exist returns null
    try std.testing.expect(fdt.cancelEntry(0, 42) == null);
}

pub const Readiness = enum(u2) {
    none = 0,
    rd = 1,
    wr = 2,
    rdwr = 3,

    pub fn isReadable(rdy: Readiness) bool {
        const rd = @enumToInt(Readiness.rd);
        return ((@enumToInt(rdy) & rd) == rd);
    }

    pub fn isWritable(rdy: Readiness) bool {
        const wr = @enumToInt(Readiness.wr);
        return ((@enumToInt(rdy) & wr) == wr);
    }
};

test "readiness" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(false, Readiness.isReadable(.none));
    try expectEqual(false, Readiness.isReadable(.wr));
    try expectEqual(true, Readiness.isReadable(.rd));
    try expectEqual(true, Readiness.isReadable(.rdwr));

    try expectEqual(false, Readiness.isWritable(.none));
    try expectEqual(false, Readiness.isWritable(.rd));
    try expectEqual(true, Readiness.isWritable(.wr));
    try expectEqual(true, Readiness.isWritable(.rdwr));
}
