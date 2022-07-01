//! Vortex is a Zig library for structured concurrency and asynchronous event
//! processing. It builds on Zig's language support for async functions
//! (suspend/resume and async/await), providing the user with ergonomic task
//! spawning, joining, cancellation, and timeouts.
//!
//! This file provides the public API for Vortex, including access methods for:
//!   - basic lifecycle management of the runtime
//!   - task spawning, joining, and cancellation
//!   - timekeeping and task-safe waiting ('sleeping')
//!   - network communication
//!   - recording events into a log or other event stream
//!
//! See the top-level README for more information and a feature roadmap.
//!
const std = @import("std");
const root = @import("root");

const ztracy = @import("ztracy");

const EventRegistry = @import("src/event.zig").EventRegistry;

const clock = @import("src/clock.zig");
const metricslib = @import("src/metrics.zig");
const network = @import("src/network.zig");
const runtime = @import("src/runtime.zig");

pub const Vortex = if (@hasDecl(root, "Runtime"))
    VortexImpl(root.Runtime)
else
    VortexImpl(runtime.DefaultRuntime);

pub const SimVortex = VortexImpl(runtime.SimRuntime);

fn VortexImpl(comptime R: type) type {
    return struct {
        pub const Config = R.Config;
        pub const Timespec = clock.Timespec;

        pub const DefaultTestConfig = R.Config{};

        const Network = network.Impl(R);
        const Scheduler = R.Scheduler;

        var _instance: R = undefined;

        pub fn init(alloc: std.mem.Allocator, config: R.Config) !void {
            _instance = try R.init(alloc, config);
        }

        pub fn deinit(alloc: std.mem.Allocator) void {
            _instance.deinit(alloc);
        }

        pub fn run(
            comptime initFn: anytype,
            initArgs: anytype,
        ) anyerror!void {
            return _instance.run(initFn, initArgs);
        }

        /// Task spawning operations and types
        pub const task = struct {
            /// The currently running task id
            pub fn id() Scheduler.TaskId {
                return _instance.sched.currentTaskId();
            }

            /// A SpawnHandle holds the task-specific stack frame and associated state
            /// necessary to implement the handle's join() and cancel() methods.
            /// The intended usage is:
            ///
            ///     var handle: vx.SpawnHandle(my_entry) = undefined;
            ///     try vx.spawn(&handle, .{ ... }, timeout);
            ///
            pub fn SpawnHandle(comptime entry: anytype) type {
                return Scheduler.SpawnHandle(entry);
            }

            /// Spawns the task defined by spawnHandlePtr, passing args in as the entry
            /// point arguments. If the task is not completed before req_timeout, it
            /// is cancelled by the runtime and it returns a TaskTimeout error. If
            /// that task has spawned child tasks, those and all their dependents are
            /// also cancelled with TaskTimeout errors.
            pub fn spawn(
                spawnHandlePtr: anytype,
                args: anytype,
                req_timeout: ?Timespec,
            ) Scheduler.SpawnError!void {
                const timeout = if (req_timeout) |t| t else clock.max_time;
                return _instance.sched.spawnTask(spawnHandlePtr, args, timeout);
            }

            /// Waits for one of several tasks to complete, and cancels all
            /// others. Expects `spawn_handles` to be a struct with one field
            /// per task handle, and returns a tagged union of the task return
            /// types, tagged by the task that completed first.
            pub fn select(
                spawn_handles: anytype,
            ) error{TaskCancelled}!Scheduler.SelectResultUnion(@TypeOf(spawn_handles)) {
                return _instance.sched.select(spawn_handles);
            }
        };

        /// Timekeeping methods
        pub const time = struct {
            /// Returns the current monotonic clock value, in nanoseconds elapsed since
            /// an unspecified point in real-time.
            /// TODO: remove this API, in favor of (1) a realtime() method for getting
            /// the wall-clock time, and (2) an interval API to measure elapsed nanos
            /// We should not expose the absolute value here for clients to somehow
            /// rely on, as the basis value has no portable meaning.
            pub fn now() Timespec {
                return _instance.clock.now();
            }

            /// Suspend this task for interval nanoseconds
            pub fn sleep(interval: Timespec) Scheduler.SuspendError!void {
                return _instance.io().sleep(interval);
            }
        };

        /// Networking methods
        pub const net = struct {
            pub const TcpListener = Network.Listener;
            pub const TcpStream = Network.Stream;

            /// Start a listener socket at the given address. Call accept() on
            /// the returned TcpListener object to accept incoming connections.
            pub fn startTcpListener(
                addr: std.net.Address,
                backlog: u31,
            ) TcpListener.InitError!TcpListener {
                return TcpListener.init(&_instance, addr, backlog);
            }

            /// Open a TCP connection to a server listening at the given address.
            /// Returns an IoTimeout error if the connection has not been made (and no
            /// other error occurred) after timeout nanoseconds.
            pub fn openTcpStream(
                target: std.net.Address,
                timeout: ?Timespec,
            ) TcpStream.ConnectError!TcpStream {
                return TcpStream.connect(&_instance, target, timeout);
            }
        };

        /// Synchronization methods
        pub const sync = struct {
            const Atomic = std.atomic.Atomic;

            /// Task-aware Futex primitive
            pub const Futex = struct {
                const FutexImpl = @import("src/sync/futex.zig").Futex;

                pub fn wait(
                    ptr: *const Atomic(u32),
                    expect: u32,
                    timeout: ?Timespec,
                ) !void {
                    return FutexImpl(R).wait(&_instance, ptr, expect, timeout);
                }

                pub fn wake(ptr: *const Atomic(u32), max_waiters: usize) void {
                    FutexImpl(R).wake(&_instance, ptr, max_waiters);
                }
            };

            /// Task-aware barrier synchronization
            pub const Barrier = @import("src/sync/barrier.zig").Barrier(Futex);
        };

        /// Metrics tracking
        pub const metrics = struct {
            pub usingnamespace metricslib;
        };

        /// Tracing with tracy
        pub const tracing = struct {
            pub usingnamespace ztracy;
        };

        /// Event logging methods
        pub const event = struct {

            /// Emit an Event object with user-defined payload
            pub fn emit(comptime Event: type, user: Event.User) void {
                _instance.emitter.emit(
                    _instance.clock.now(),
                    runtime.threadId(),
                    Event,
                    user,
                );
            }

            /// Construct a scoped registry with the given namespace and enum of
            /// event tags
            pub fn Registry(
                comptime namespace: []const u8,
                comptime TagEnum: type,
            ) type {
                return EventRegistry(namespace, TagEnum);
            }
        };

        /// Testing-related methods
        pub const testing = struct {
            /// Convenience method to reduce boilerplate when writing tests.
            pub fn runTest(
                alloc: std.mem.Allocator,
                config: R.Config,
                comptime initFn: anytype,
                initArgs: anytype,
            ) anyerror!void {
                try init(alloc, config);
                defer deinit(alloc);

                try _instance.run(initFn, initArgs);
            }

            pub fn unusedTcpPort() !std.net.Address {
                return Network.testing.unusedTcpPort(&_instance);
            }
        };
    };
}

test "api" {
    _ = @import("tests/timer.zig"); // TODO: re-enable Sim tests
    _ = @import("tests/task.zig"); // TODO: re-enable Sim tests
    _ = @import("tests/cancel.zig"); // TODO: re-enable Sim tests
    _ = @import("tests/tcp.zig");
    _ = @import("tests/futex.zig");
    _ = @import("tests/barrier.zig");
    _ = @import("tests/select.zig");
}
