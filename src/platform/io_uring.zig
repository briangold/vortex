const std = @import("std");
const assert = std.debug.assert;

const IoUring = std.os.linux.IO_Uring;
const CompletionEvent = std.os.linux.io_uring_cqe;

const Timespec = @import("../clock.zig").Timespec;
const CancelToken = @import("../scheduler.zig").CancelToken;
const Emitter = @import("../event.zig").Emitter;
const EventRegistry = @import("../event.zig").EventRegistry;
const max_time = @import("../clock.zig").max_time;
const threadId = @import("../runtime.zig").threadId;

const internal_timeout_userdata = std.math.maxInt(usize);
const internal_cancel_userdata = std.math.maxInt(usize) - 1;
const internal_link_timeout_userdata = std.math.maxInt(usize) - 2;

pub fn LoopFactory(comptime Scheduler: type) type {
    return struct {
        pub const Config = struct {
            /// Desired number of submission-queue entries. Must be a power-of-2
            /// between 1 and 4096.
            num_entries: u13 = 4096,

            /// Limit on how many completions can be reaped in a single call
            /// to poll().
            max_poll_events: usize = 128,
        };

        pub const Descriptor = std.os.fd_t;
        pub const Scheduler = Scheduler;

        const Loop = @This();

        const IoOperation = IoOperationImpl(Loop);
        const IoCompletion = IoOperation.IoCompletion;

        clock: *Scheduler.Clock,
        sched: *Scheduler,
        emitter: *Emitter,
        io_uring: IoUring,
        pending: usize,
        events: []CompletionEvent,

        pub const InitError = anyerror; // TODO: more precise

        pub fn init(
            alloc: std.mem.Allocator,
            config: Config,
            sched: *Scheduler,
            emitter: *Emitter,
        ) InitError!Loop {
            // If we want to support additional flags, we should expose them
            // as discrete config options/enum choices, then convert to the
            // bitfield flags here. For now the defaults are fine.
            const io_uring_flags: u32 = 0;

            return Loop{
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
            };
        }

        pub fn deinit(self: *Loop, alloc: std.mem.Allocator) void {
            self.io_uring.deinit();
            alloc.free(self.events);
        }

        /// Polls for event completions, triggering the registered wakeup
        /// callback (typically to reschedule a task for continued execution).
        /// Waits up to `timeout' nanoseconds for a completion. Returns the
        /// number of completions handled.
        pub fn poll(self: *Loop, timeout_ns: Timespec) !usize {
            // Prep an internal timeout to limit how long we wait for a
            // completion NOTE: we use relative timeouts here and are expressing
            // the delay in whatever form of clock the kernel uses
            // (CLOCK_MONOTONIC), not necessarily the clock we're using for
            // other timeouts and events.
            const timeout_spec = std.os.linux.kernel_timespec{
                .tv_sec = 0,
                .tv_nsec = @intCast(isize, timeout_ns),
            };

            _ = self.io_uring.timeout(
                internal_timeout_userdata,
                &timeout_spec,
                1, // count => don't set res to -ETIME if we get a completion
                0, // relative timeout
            ) catch |err| {
                std.debug.panic("Unable to submit internal timeout: {}\n", .{err});
            };

            // submit all pending sqes and wait for one (worst case, our timeout)
            _ = self.io_uring.submit_and_wait(1) catch |err| {
                std.debug.panic("Unable to submit_and_wait: {}\n", .{err});
            };

            const completed = self.io_uring.copy_cqes(self.events, 0) catch |err| {
                std.debug.panic("Unable to copy_cqes: {}\n", .{err});
            };

            var user_events: usize = 0;
            var i: usize = 0;
            while (i < completed) : (i += 1) {
                const cqe = &self.events[i];

                switch (cqe.user_data) {
                    internal_timeout_userdata,
                    internal_cancel_userdata,
                    internal_link_timeout_userdata,
                    => {
                        // Internal events require no callback or further processing
                    },

                    else => {
                        user_events += 1;
                        self.pending -= 1;

                        const op = @intToPtr(*IoOperation, cqe.user_data);

                        // stuff the result into our user-visible completion
                        op.completion.result = cqe.res;

                        self.emitEvent(IoWakeEvent, .{ .op = op });

                        // wake the callback
                        op.completion.callback(
                            op.completion.callback_ctx,
                            op.completion.callback_data,
                        );
                    },
                }
            }

            return user_events;
        }

        pub fn hasPending(self: *Loop) bool {
            return self.pending != 0;
        }

        fn emitEvent(
            self: *Loop,
            comptime Event: type,
            user: Event.User,
        ) void {
            self.emitter.emit(self.clock.now(), threadId(), Event, user);
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
            self: *Loop,
            listen_fd: Descriptor,
            addr: *std.os.sockaddr,
            addrlen: *std.os.socklen_t,
            flags: u32,
            timeout: Timespec,
        ) !Descriptor {
            var op = IoOperation{
                .loop = self,
                .args = .{
                    .accept = .{
                        .listen_fd = listen_fd,
                        .addr = addr,
                        .addrlen = addrlen,
                        .flags = flags,
                    },
                },
            };
            try self.sched.suspendTask(timeout, &op);
            return @intCast(Descriptor, try op.complete());
        }

        pub fn connect(
            self: *Loop,
            fd: Descriptor,
            addr: *std.os.sockaddr,
            addrlen: std.os.socklen_t,
            timeout: Timespec,
        ) !Descriptor {
            var op = IoOperation{
                .loop = self,
                .args = .{
                    .connect = .{
                        .fd = fd,
                        .addr = addr,
                        .addrlen = addrlen,
                    },
                },
            };
            try self.sched.suspendTask(timeout, &op);
            return @intCast(Descriptor, try op.complete());
        }

        pub fn recv(
            self: *Loop,
            fd: Descriptor,
            buffer: []u8,
            flags: u32,
            timeout: Timespec,
        ) !usize {
            var op = IoOperation{
                .loop = self,
                .args = .{
                    .recv = .{
                        .fd = fd,
                        .buffer = buffer,
                        .flags = flags,
                    },
                },
            };
            try self.sched.suspendTask(timeout, &op);
            return op.complete();
        }

        pub fn send(
            self: *Loop,
            fd: Descriptor,
            buffer: []const u8,
            flags: u32,
            timeout: Timespec,
        ) !usize {
            var op = IoOperation{
                .loop = self,
                .args = .{
                    .send = .{
                        .fd = fd,
                        .buffer = buffer,
                        .flags = flags,
                    },
                },
            };
            try self.sched.suspendTask(timeout, &op);
            return op.complete();
        }

        pub fn sleep(self: *Loop, interval: Timespec) !void {
            var op = IoOperation{
                .loop = self,
                .args = .sleep,
            };
            try self.sched.suspendTask(interval, &op);
            _ = try op.complete();
        }

        /// Implements the I/O loop operations for a Futex. See the platform-
        /// independent Futex library for more information.
        pub const FutexEvent = struct {
            op: IoOperation,

            pub fn init(loop: *Loop) FutexEvent {
                return FutexEvent{
                    .op = IoOperation{
                        .loop = loop,
                        .args = .{ .futex_wait = .{
                            .state = .{ .value = .empty },
                        } },
                    },
                };
            }

            /// Waits for a wakeup event (no error) or the timeout to expire.
            pub fn wait(tl: *FutexEvent, maybe_timeout: ?Timespec) !void {
                const timeout = maybe_timeout orelse max_time;
                try tl.op.loop.sched.suspendTask(timeout, &tl.op);

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
                        .waiting => {
                            // cancel waiting op
                            tl.op.cancel();
                            return;
                        },
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

fn IoOperationImpl(comptime Loop: type) type {
    return struct {
        const Self = @This();

        const Descriptor = Loop.Descriptor;
        const IoCompletion = struct {
            result: i32 = 0,
            callback: fn (*anyopaque, usize) void,
            callback_ctx: *anyopaque,
            callback_data: usize,
        };

        // common elements
        loop: *Loop,
        completion: IoCompletion = undefined,
        timeout: std.os.linux.kernel_timespec = undefined,

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
        },

        pub fn prep(
            op: *Self,
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

            op.loop.pending += 1;

            op.loop.emitEvent(Loop.IoSuspendEvent, .{ .op = op });

            switch (op.args) {
                .sleep => {
                    _ = try op.loop.io_uring.timeout(
                        @ptrToInt(op),
                        &op.timeout,
                        0, // count => wait independent of other events
                        0, // relative timeout
                    );
                },

                .futex_wait => |*args| {
                    _ = try op.loop.io_uring.timeout(
                        @ptrToInt(op),
                        &op.timeout,
                        0, // count => wait independent of other events
                        0, // relative timeout
                    );

                    // state transition loop - atomically transition:
                    //   empty    => waiting  :: the waker will see waiting
                    //   notified => _        :: already notified, so cancel
                    while (true) {
                        switch (args.state.load(.Acquire)) {
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
                            .waiting => unreachable,
                            .notified => {
                                // notification already arrived, cancel
                                op.cancel();
                                return;
                            },
                        }
                    }
                },

                .accept => |*args| {
                    var sqe = try op.loop.io_uring.accept(
                        @ptrToInt(op),
                        args.listen_fd,
                        args.addr,
                        args.addrlen,
                        args.flags,
                    );

                    sqe.flags |= std.os.linux.IOSQE_IO_LINK;

                    _ = try op.loop.io_uring.link_timeout(
                        internal_link_timeout_userdata,
                        &op.timeout,
                        0, // relative timeout
                    );
                },

                .connect => |*args| {
                    var sqe = try op.loop.io_uring.connect(
                        @ptrToInt(op),
                        args.fd,
                        args.addr,
                        args.addrlen,
                    );

                    sqe.flags |= std.os.linux.IOSQE_IO_LINK;

                    _ = try op.loop.io_uring.link_timeout(
                        internal_link_timeout_userdata,
                        &op.timeout,
                        0, // relative timeout
                    );
                },

                .recv => |*args| {
                    var sqe = try op.loop.io_uring.recv(
                        @ptrToInt(op),
                        args.fd,
                        .{ .buffer = args.buffer },
                        args.flags,
                    );

                    sqe.flags |= std.os.linux.IOSQE_IO_LINK;

                    _ = try op.loop.io_uring.link_timeout(
                        internal_link_timeout_userdata,
                        &op.timeout,
                        0, // relative timeout
                    );
                },

                .send => |*args| {
                    var sqe = try op.loop.io_uring.send(
                        @ptrToInt(op),
                        args.fd,
                        args.buffer,
                        args.flags,
                    );

                    sqe.flags |= std.os.linux.IOSQE_IO_LINK;

                    _ = try op.loop.io_uring.link_timeout(
                        internal_link_timeout_userdata,
                        &op.timeout,
                        0, // relative timeout
                    );
                },
            }
        }

        pub fn complete(op: *Self) !usize {
            switch (op.args) {
                .sleep => {
                    const ETIME = -@as(i32, @enumToInt(std.os.linux.E.TIME));
                    assert(op.completion.result == ETIME);
                    return @as(usize, 0);
                },

                .futex_wait => {
                    if (op.completion.result < 0) {
                        return switch (@intToEnum(std.os.E, -op.completion.result)) {
                            .CANCELED => @as(usize, 0),
                            .TIME => error.Timeout,
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
            }
        }

        fn cancel(op: *Self) void {
            op.loop.emitEvent(Loop.IoCancelEvent, .{ .op = op });

            switch (op.args) {
                // cancellable operations
                .sleep,
                .futex_wait,
                => {
                    // this queues the cancellation as a SQE, which will be
                    // processed by the poll() loop like any other
                    _ = op.loop.io_uring.timeout_remove(
                        internal_cancel_userdata,
                        @ptrToInt(op),
                        0,
                    ) catch |err| {
                        std.debug.panic("timeout_remove failed: {s}", .{err});
                    };
                },
                .accept,
                .connect,
                .recv,
                .send,
                => {
                    // this queues the cancellation as a SQE, which will be
                    // processed by the poll() loop like any other
                    _ = op.loop.io_uring.cancel(
                        internal_cancel_userdata,
                        @ptrToInt(op),
                        0,
                    ) catch |err| {
                        std.debug.panic("cancellation failed: {s}", .{err});
                    };
                },
            }
        }

        pub fn cancelToken(op: *Self) CancelToken {
            return CancelToken.init(op, cancel);
        }

        pub fn format(
            op: *const Self,
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
            }

            if (op.timeout.tv_nsec == max_time) {
                try writer.writeAll(" deadline=inf");
            } else {
                const abs_timeout = op.loop.clock.now() + op.timeout.tv_nsec;
                try writer.print(" deadline={d}", .{abs_timeout});
            }
        }
    };
}
