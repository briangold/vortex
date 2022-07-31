const std = @import("std");
const assert = std.debug.assert;

const ztracy = @import("ztracy");

const IoUring = std.os.linux.IO_Uring;
const CompletionEvent = std.os.linux.io_uring_cqe;
const SubmissionEntry = std.os.linux.io_uring_sqe;

const Timespec = @import("../clock.zig").Timespec;
const CancelToken = @import("../scheduler.zig").CancelToken;
const EventRegistry = @import("../event.zig").EventRegistry;
const CancelQueue = @import("cancel_queue.zig").CancelQueue;
const max_time = @import("../clock.zig").max_time;
const threadId = @import("../runtime.zig").threadId;

const internal_timeout_userdata = std.math.maxInt(usize);
const internal_cancel_userdata = std.math.maxInt(usize) - 1;
const internal_link_timeout_userdata = std.math.maxInt(usize) - 2;

pub fn IoUringPlatform(comptime Scheduler: type) type {
    const Emitter = @import("../event.zig").Emitter(Scheduler.Clock);

    return struct {
        pub const Config = struct {
            /// Desired number of submission-queue entries. Must be a power-of-2
            /// between 1 and 4096. TODO: enforce real lower limit of 4 due to reserve ops
            num_entries: u13 = 1024,

            /// Limit on how many completions can be reaped in a single call
            /// to poll().
            max_poll_events: usize = 128,
        };

        pub const Descriptor = std.os.fd_t;
        pub const Scheduler = Scheduler;

        const Platform = @This();

        const IoOperation = IoOperationImpl(Platform);
        const IoCompletion = IoOperation.IoCompletion;

        clock: *Scheduler.Clock,
        sched: *Scheduler,
        emitter: *Emitter,
        io_uring: IoUring,
        pending: usize,
        events: []CompletionEvent,
        cancelq: CancelQueue(IoOperation, "cancel_next"),

        pub const InitError = anyerror; // TODO: more precise

        pub fn init(
            alloc: std.mem.Allocator,
            config: Config,
            sched: *Scheduler,
            emitter: *Emitter,
        ) InitError!Platform {
            // If we want to support additional flags, we should expose them
            // as discrete config options/enum choices, then convert to the
            // bitfield flags here. For now the defaults are fine.
            const io_uring_flags: u32 = 0;

            return Platform{
                .clock = sched.clock,
                .sched = sched,
                .emitter = emitter,
                .io_uring = try IoUring.init(
                    config.num_entries,
                    io_uring_flags,
                ),
                .pending = 0,
                .events = try alloc.alloc(
                    CompletionEvent,
                    config.max_poll_events,
                ),
                .cancelq = .{},
            };
        }

        pub fn deinit(platform: *Platform, alloc: std.mem.Allocator) void {
            platform.io_uring.deinit();
            alloc.free(platform.events);
        }

        /// Polls for event completions, triggering the registered wakeup
        /// callback (typically to reschedule a task for continued execution).
        /// Waits up to `timeout' nanoseconds for a completion. Returns the
        /// number of completions handled.
        pub fn poll(platform: *Platform, timeout_ns: Timespec) !usize {
            // Prep an internal timeout to limit how long we wait for a
            // completion NOTE: we use relative timeouts here and are expressing
            // the delay in whatever form of clock the kernel uses
            // (CLOCK_MONOTONIC), not necessarily the clock we're using for
            // other timeouts and events.
            const timeout_spec = std.os.linux.kernel_timespec{
                .tv_sec = 0,
                .tv_nsec = @intCast(isize, timeout_ns),
            };

            // submit our internal timeout that limits poll duration
            var sqe = platform.getSQEntry();
            std.os.linux.io_uring_prep_timeout(
                sqe,
                &timeout_spec,
                1, // count => don't set res to -ETIME if we get completion
                0, // relative timeout
            );
            sqe.user_data = internal_timeout_userdata;

            // submit all pending sqes
            const submitted = platform.io_uring.submit() catch |err| {
                std.debug.panic("Unable to submit_and_wait: {}\n", .{err});
            };

            ztracy.PlotU("sqes", submitted);

            // copy completions, and if none available, wait for at least
            // one (our timeout) to arrive
            const completed = platform.io_uring.copy_cqes(platform.events, 1) catch |err| {
                std.debug.panic("Unable to copy_cqes: {}\n", .{err});
            };

            ztracy.PlotU("cqes_post", completed);

            var user_events: usize = 0;
            var i: usize = 0;
            while (i < completed) : (i += 1) {
                const cqe = &platform.events[i];

                switch (cqe.user_data) {
                    0 => {
                        std.debug.panic(
                            "Unexpected cqe user data 0: {any}\n",
                            .{cqe},
                        );
                    },

                    internal_timeout_userdata,
                    internal_cancel_userdata,
                    internal_link_timeout_userdata,
                    => {
                        // Internal events require no callback or further processing
                    },

                    else => {
                        user_events += 1;
                        platform.pending -= 1;

                        const op = @intToPtr(*IoOperation, cqe.user_data);

                        // stuff the result into our user-visible completion
                        op.completion.result = cqe.res;

                        platform.emitEvent(IoWakeEvent, .{ .op = op });

                        // wake the callback
                        op.completion.callback(
                            op.completion.callback_ctx,
                            op.completion.callback_data,
                        );
                    },
                }
            }

            var to_cancel = platform.cancelq.unlink();
            var needs_flush = (to_cancel.get() != null);
            while (to_cancel.get()) |op| : (_ = to_cancel.next()) {
                needs_flush = true;

                // Queue the cancellation as a SQE, which will be processed by
                // the poll() loop like any other
                var cancel_sqe = platform.getSQEntry();

                switch (op.args) {
                    // timeout-based operations
                    .sleep,
                    .futex_wait,
                    => {
                        std.os.linux.io_uring_prep_timeout_remove(
                            cancel_sqe,
                            @ptrToInt(op),
                            0,
                        );
                    },

                    // I/O based operations
                    .accept,
                    .connect,
                    .recv,
                    .send,
                    .read,
                    .write,
                    => {
                        std.os.linux.io_uring_prep_cancel(
                            cancel_sqe,
                            @ptrToInt(op),
                            0,
                        );
                    },
                }

                // We get the useful CQE back from the original submission,
                // and can safely ignore the cancellation CQE in poll()
                cancel_sqe.user_data = internal_cancel_userdata;
            }

            // flush cancellations
            if (needs_flush) _ = platform.io_uring.submit() catch |err|
                std.debug.panic("io_uring cancellation submit failed: {}", .{err});

            return user_events;
        }

        pub fn hasPending(platform: *Platform) bool {
            return platform.pending != 0;
        }

        fn getSQEntry(
            platform: *Platform,
        ) *SubmissionEntry {
            if (platform.io_uring.get_sqe()) |sqe| {
                return sqe;
            } else |err| {
                assert(err == error.SubmissionQueueFull);

                // submit, but don't wait for any completions
                _ = platform.io_uring.submit() catch |err2|
                    std.debug.panic("io_uring enter() failed: {}", .{err2});

                // try again
                if (platform.io_uring.get_sqe()) |sqe| {
                    return sqe;
                } else |err2| {
                    std.debug.panic("io_uring get_sqe() failed: {}", .{err2});
                }
            }
        }

        fn emitEvent(
            platform: *Platform,
            comptime Event: type,
            user: Event.User,
        ) void {
            platform.emitter.emit(platform.clock, threadId(), Event, user);
        }

        const posix = @import("posix_sockets.zig");

        pub const socket = posix.socket;
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
            var op = IoOperation{
                .platform = platform,
                .args = .{
                    .accept = .{
                        .listen_fd = listen_fd,
                        .addr = addr,
                        .addrlen = addrlen,
                        .flags = flags,
                    },
                },
            };
            try platform.sched.suspendTask(timeout, &op);
            return @intCast(Descriptor, try op.complete());
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
                .args = .{
                    .connect = .{
                        .fd = fd,
                        .addr = addr,
                        .addrlen = addrlen,
                    },
                },
            };
            try platform.sched.suspendTask(timeout, &op);
            return @intCast(Descriptor, try op.complete());
        }

        pub fn recv(
            platform: *Platform,
            fd: Descriptor,
            buffer: []u8,
            flags: u32,
            timeout: Timespec,
        ) !usize {
            var op = IoOperation{
                .platform = platform,
                .args = .{
                    .recv = .{
                        .fd = fd,
                        .buffer = buffer,
                        .flags = flags,
                    },
                },
            };
            try platform.sched.suspendTask(timeout, &op);
            return op.complete();
        }

        pub fn send(
            platform: *Platform,
            fd: Descriptor,
            buffer: []const u8,
            flags: u32,
            timeout: Timespec,
        ) !usize {
            var op = IoOperation{
                .platform = platform,
                .args = .{
                    .send = .{
                        .fd = fd,
                        .buffer = buffer,
                        .flags = flags,
                    },
                },
            };
            try platform.sched.suspendTask(timeout, &op);
            return op.complete();
        }

        pub fn read(
            platform: *Platform,
            fd: Descriptor,
            buffer: []u8,
            offset: u64,
            timeout: Timespec,
        ) !usize {
            var op = IoOperation{
                .platform = platform,
                .args = .{
                    .read = .{
                        .fd = fd,
                        .buffer = buffer,
                        .offset = offset,
                    },
                },
            };
            try platform.sched.suspendTask(timeout, &op);
            return op.complete();
        }

        pub fn write(
            platform: *Platform,
            fd: Descriptor,
            buffer: []const u8,
            offset: u64,
            timeout: Timespec,
        ) !usize {
            var op = IoOperation{
                .platform = platform,
                .args = .{
                    .write = .{
                        .fd = fd,
                        .buffer = buffer,
                        .offset = offset,
                    },
                },
            };
            try platform.sched.suspendTask(timeout, &op);
            return op.complete();
        }

        pub fn sleep(platform: *Platform, interval: Timespec) !void {
            var op = IoOperation{
                .platform = platform,
                .args = .sleep,
            };
            try platform.sched.suspendTask(interval, &op);
            _ = try op.complete();
        }

        /// Implements the I/O operations for a Futex. See the platform-
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

                _ = try tl.op.complete();
            }

            /// Notifies the wait-half of this event, canceling the timeout
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

                        // The waiter arrived first, so cancel its timeout. This
                        // causes the waiter to "wake up" with a ECANCELLED
                        // return code, delivered to the op complete() method.
                        .waiting => {
                            // Update the state. In the rare case where a waiter
                            // observes that it has been removed from the
                            // WaitQueue, this state update ensures the 2nd,
                            // indefinite wait doesn't block.
                            state.store(.notified, .Release);

                            // cancel waiting op
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
        });
        const IoCancelEvent = ScopedRegistry.register(.io_cancel, .debug, struct {
            op: *IoOperation,
        });
    };
}

fn IoOperationImpl(comptime Platform: type) type {
    return struct {
        const IoOperation = @This();

        const Descriptor = Platform.Descriptor;
        const IoCompletion = struct {
            result: i32 = 0,
            callback: fn (*anyopaque, usize) void,
            callback_ctx: *anyopaque,
            callback_data: usize,
        };

        // common elements
        platform: *Platform,
        completion: IoCompletion = undefined,
        timeout: std.os.linux.kernel_timespec = undefined,
        cancel_next: ?*IoOperation = null, // cancel queue linkage

        // per-opcode arguments
        args: union(enum) {
            sleep, // reuse common timeout field
            futex_wait: struct {
                const State = enum(u8) { empty, waiting, notified };
                state: std.atomic.Atomic(State),
            },
            accept: struct {
                listen_fd: Descriptor,
                addr: *std.os.sockaddr,
                addrlen: *std.os.socklen_t,
                flags: u32,
            },
            connect: struct {
                fd: Descriptor,
                addr: *std.os.sockaddr,
                addrlen: std.os.socklen_t,
            },
            recv: struct {
                fd: Descriptor,
                buffer: []u8,
                flags: u32,
            },
            send: struct {
                fd: Descriptor,
                buffer: []const u8,
                flags: u32,
            },
            read: struct {
                fd: Descriptor,
                buffer: []u8,
                offset: u64,
            },
            write: struct {
                fd: Descriptor,
                buffer: []const u8,
                offset: u64,
            },
        },

        pub fn prep(
            op: *IoOperation,
            timeout: Timespec,
            comptime callback: anytype,
            callback_ctx: anytype,
            callback_data: usize,
        ) !void {
            op.timeout = std.os.linux.kernel_timespec{
                .tv_sec = 0,
                .tv_nsec = @intCast(isize, timeout),
            };

            op.completion = IoCompletion{
                .callback = callback,
                .callback_ctx = callback_ctx,
                .callback_data = callback_data,
            };

            op.platform.pending += 1;

            op.platform.emitEvent(Platform.IoSuspendEvent, .{ .op = op });

            switch (op.args) {
                .sleep => {
                    var sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_timeout(
                        sqe,
                        &op.timeout,
                        0, // count => wait independent of other events
                        0, // relative timeout
                    );
                    sqe.user_data = @ptrToInt(op);
                },

                .futex_wait => |*args| {
                    var sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_timeout(
                        sqe,
                        &op.timeout,
                        0, // count => wait independent of other events
                        0, // relative timeout
                    );
                    sqe.user_data = @ptrToInt(op);

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

                            // notification already arrived, cancel
                            .notified => {
                                op.cancel();
                                return;
                            },
                        }
                    }
                },

                .accept => |*args| {
                    var sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_accept(
                        sqe,
                        args.listen_fd,
                        args.addr,
                        args.addrlen,
                        args.flags,
                    );
                    sqe.user_data = @ptrToInt(op);
                    sqe.flags |= std.os.linux.IOSQE_IO_LINK;

                    sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_link_timeout(
                        sqe,
                        &op.timeout,
                        0, // relative timeout
                    );
                    sqe.user_data = internal_link_timeout_userdata;
                },

                .connect => |*args| {
                    var sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_connect(
                        sqe,
                        args.fd,
                        args.addr,
                        args.addrlen,
                    );
                    sqe.user_data = @ptrToInt(op);
                    sqe.flags |= std.os.linux.IOSQE_IO_LINK;

                    sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_link_timeout(
                        sqe,
                        &op.timeout,
                        0, // relative timeout
                    );
                    sqe.user_data = internal_link_timeout_userdata;
                },

                .recv => |*args| {
                    var sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_recv(
                        sqe,
                        args.fd,
                        args.buffer,
                        args.flags,
                    );
                    sqe.user_data = @ptrToInt(op);
                    sqe.flags |= std.os.linux.IOSQE_IO_LINK;

                    sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_link_timeout(
                        sqe,
                        &op.timeout,
                        0, // relative timeout
                    );
                    sqe.user_data = internal_link_timeout_userdata;
                },

                .send => |*args| {
                    var sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_send(
                        sqe,
                        args.fd,
                        args.buffer,
                        args.flags,
                    );
                    sqe.user_data = @ptrToInt(op);
                    sqe.flags |= std.os.linux.IOSQE_IO_LINK;

                    sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_link_timeout(
                        sqe,
                        &op.timeout,
                        0, // relative timeout
                    );
                    sqe.user_data = internal_link_timeout_userdata;
                },

                .read => |*args| {
                    var sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_read(
                        sqe,
                        args.fd,
                        args.buffer,
                        args.offset,
                    );
                    sqe.user_data = @ptrToInt(op);
                    sqe.flags |= std.os.linux.IOSQE_IO_LINK;

                    sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_link_timeout(
                        sqe,
                        &op.timeout,
                        0, // relative timeout
                    );
                    sqe.user_data = internal_link_timeout_userdata;
                },

                .write => |*args| {
                    var sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_write(
                        sqe,
                        args.fd,
                        args.buffer,
                        args.offset,
                    );
                    sqe.user_data = @ptrToInt(op);
                    sqe.flags |= std.os.linux.IOSQE_IO_LINK;

                    sqe = op.platform.getSQEntry();
                    std.os.linux.io_uring_prep_link_timeout(
                        sqe,
                        &op.timeout,
                        0, // relative timeout
                    );
                    sqe.user_data = internal_link_timeout_userdata;
                },
            }
        }

        pub fn complete(op: *IoOperation) !usize {
            switch (op.args) {
                .sleep => {
                    if (op.completion.result < 0) {
                        return switch (@intToEnum(std.os.E, -op.completion.result)) {
                            .TIME => @as(usize, 0),
                            else => |err| std.debug.panic("Unexpected error: {}", .{err}),
                        };
                    } else unreachable;
                },

                .futex_wait => {
                    if (op.completion.result < 0) {
                        return switch (@intToEnum(std.os.E, -op.completion.result)) {
                            // When a waiter is "notified", the waiter's timeout
                            // operation is cancelled, causing the ECANCELED
                            // return here. We turn this into a non-error return
                            // code.
                            .CANCELED => @as(usize, 0),

                            // If the waiter isn't notified in time, return a
                            // FutexTimeout, which we keep separate from a
                            // TaskTimeout that may also occur.
                            .TIME => error.FutexTimeout,

                            else => unreachable,
                        };
                    } else unreachable;
                },

                .accept => {
                    if (op.completion.result < 0) {
                        return switch (@intToEnum(std.os.E, -op.completion.result)) {
                            .AGAIN => error.WouldBlock,
                            .BADF => error.FileDescriptorInvalid,
                            .CANCELED => error.IoCanceled,
                            .CONNABORTED => error.ConnectionAborted,
                            .FAULT => unreachable,
                            .INTR => unreachable,
                            .INVAL => error.SocketNotListening,
                            .MFILE => error.ProcessFdQuotaExceeded,
                            .NFILE => error.SystemFdQuotaExceeded,
                            .NOBUFS => error.SystemResources,
                            .NOMEM => error.SystemResources,
                            .NOTSOCK => error.FileDescriptorNotASocket,
                            .OPNOTSUPP => error.OperationNotSupported,
                            .PERM => error.PermissionDenied,
                            .PROTO => error.ProtocolFailure,
                            else => |errno| std.os.unexpectedErrno(errno),
                        };
                    } else {
                        return @intCast(usize, op.completion.result);
                    }
                },

                .connect => {
                    if (op.completion.result < 0) {
                        return switch (@intToEnum(std.os.E, -op.completion.result)) {
                            .ACCES => error.AccessDenied,
                            .ADDRINUSE => error.AddressInUse,
                            .ADDRNOTAVAIL => error.AddressNotAvailable,
                            .AFNOSUPPORT => error.AddressFamilyNotSupported,
                            .AGAIN, .INPROGRESS => error.WouldBlock,
                            .ALREADY => error.OpenAlreadyInProgress,
                            .BADF => error.FileDescriptorInvalid,
                            .CONNREFUSED => error.ConnectionRefused,
                            .CONNRESET => error.ConnectionResetByPeer,
                            .FAULT => unreachable,
                            .INTR => unreachable,
                            .ISCONN => error.AlreadyConnected,
                            .NETUNREACH => error.NetworkUnreachable,
                            .NOENT => error.FileNotFound,
                            .NOTSOCK => error.FileDescriptorNotASocket,
                            .PERM => error.PermissionDenied,
                            .PROTOTYPE => error.ProtocolNotSupported,
                            .TIMEDOUT => error.ConnectionTimedOut,
                            else => |errno| std.os.unexpectedErrno(errno),
                        };
                    } else {
                        assert(op.completion.result == 0);
                        return @as(usize, 0);
                    }
                },

                .recv => {
                    if (op.completion.result < 0) {
                        return switch (@intToEnum(std.os.E, -op.completion.result)) {
                            .AGAIN => error.WouldBlock,
                            .BADF => error.FileDescriptorInvalid,
                            .CONNREFUSED => error.ConnectionRefused,
                            .FAULT => unreachable,
                            .INTR => unreachable,
                            .INVAL => unreachable,
                            .NOMEM => error.SystemResources,
                            .NOTCONN => error.SocketNotConnected,
                            .NOTSOCK => error.FileDescriptorNotASocket,
                            .CONNRESET => error.ConnectionResetByPeer,
                            else => |errno| std.os.unexpectedErrno(errno),
                        };
                    } else {
                        return @intCast(usize, op.completion.result);
                    }
                },

                .send => {
                    if (op.completion.result < 0) {
                        return switch (@intToEnum(std.os.E, -op.completion.result)) {
                            .ACCES => error.AccessDenied,
                            .AGAIN => error.WouldBlock,
                            .ALREADY => error.FastOpenAlreadyInProgress,
                            .AFNOSUPPORT => error.AddressFamilyNotSupported,
                            .BADF => error.FileDescriptorInvalid,
                            .CONNRESET => error.ConnectionResetByPeer,
                            .DESTADDRREQ => unreachable,
                            .FAULT => unreachable,
                            .INTR => unreachable,
                            .INVAL => unreachable,
                            .ISCONN => unreachable,
                            .MSGSIZE => error.MessageTooBig,
                            .NOBUFS => error.SystemResources,
                            .NOMEM => error.SystemResources,
                            .NOTCONN => error.SocketNotConnected,
                            .NOTSOCK => error.FileDescriptorNotASocket,
                            .OPNOTSUPP => error.OperationNotSupported,
                            .PIPE => error.BrokenPipe,
                            else => |errno| std.os.unexpectedErrno(errno),
                        };
                    } else {
                        return @intCast(usize, op.completion.result);
                    }
                },

                .read => {
                    if (op.completion.result < 0) {
                        return switch (@intToEnum(std.os.E, -op.completion.result)) {
                            .AGAIN => error.WouldBlock,
                            .BADF => error.FileDescriptorInvalid,
                            .FAULT => unreachable,
                            .INTR => unreachable,
                            .INVAL => unreachable,
                            .NOMEM => error.SystemResources,
                            .IO => error.InputOutput,
                            else => |errno| std.os.unexpectedErrno(errno),
                        };
                    } else {
                        return @intCast(usize, op.completion.result);
                    }
                },

                .write => {
                    if (op.completion.result < 0) {
                        return switch (@intToEnum(std.os.E, -op.completion.result)) {
                            .AGAIN => error.WouldBlock,
                            .BADF => error.FileDescriptorInvalid,
                            .DESTADDRREQ => unreachable,
                            .DQUOT => error.DiskQuota,
                            .FAULT => unreachable,
                            .FBIG => error.FileTooBig,
                            .INTR => unreachable,
                            .INVAL => unreachable,
                            .IO => error.InputOutput,
                            .NOMEM => error.SystemResources,
                            .NOSPC => error.NoSpaceLeft,
                            .PERM => error.AccessDenied,
                            .PIPE => error.BrokenPipe,
                            else => |errno| std.os.unexpectedErrno(errno),
                        };
                    } else {
                        return @intCast(usize, op.completion.result);
                    }
                },
            }
        }

        fn cancel(op: *IoOperation) void {
            op.platform.emitEvent(Platform.IoCancelEvent, .{ .op = op });
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

            try writer.print("{s}", .{@tagName(op.args)});

            switch (op.args) {
                .sleep, .futex_wait => {},
                .accept => |args| {
                    try writer.print(" fd={d}", .{args.listen_fd});
                },
                .connect => |args| {
                    try writer.print(" fd={d}", .{args.fd});
                },
                .recv => |args| {
                    try writer.print(" fd={d}", .{args.fd});
                },
                .send => |args| {
                    try writer.print(" fd={d}", .{args.fd});
                },
                .read => |args| {
                    try writer.print(" fd={d}", .{args.fd});
                },
                .write => |args| {
                    try writer.print(" fd={d}", .{args.fd});
                },
            }

            if (op.timeout.tv_nsec == max_time) {
                try writer.writeAll(" deadline=inf");
            } else {
                const abs_timeout = op.platform.clock.now() + op.timeout.tv_nsec;
                try writer.print(" deadline={d}", .{abs_timeout});
            }
        }
    };
}
