const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const platform = @import("platform.zig");
const scheduler = @import("scheduler.zig");
const Emitter = @import("event.zig").Emitter;
const EventRegistry = @import("event.zig").EventRegistry;

const ztracy = @import("ztracy");

threadlocal var thread_id: usize = 0;

pub fn threadId() usize {
    return thread_id;
}

pub const SimRuntime = RuntimeImpl(platform.SimIoLoop);
pub const DefaultRuntime = RuntimeImpl(platform.DefaultLoop);

pub fn RuntimeImpl(comptime Loop: type) type {
    return struct {
        const Runtime = @This();

        pub const IoLoop = Loop;
        pub const Scheduler = IoLoop.Scheduler;
        pub const Clock = Scheduler.Clock;
        pub const Config = @import("config.zig").Config(Runtime);

        emitter: *Emitter,
        clock: *Clock,
        sched: *Scheduler,
        threads: []WorkerThread,

        pub fn init(alloc: std.mem.Allocator, config: Config) !Runtime {
            var emitter = try alloc.create(Emitter);
            emitter.* = Emitter.init(config.log_level, config.event_writer);

            var clk = try alloc.create(Clock);
            clk.* = Clock{};

            var sched = try alloc.create(Scheduler);
            sched.* = try Scheduler.init(alloc, clk, emitter, config.scheduler);

            var threads = try alloc.alloc(WorkerThread, config.task_threads);
            for (threads) |*thread| {
                thread.* = try WorkerThread.init(
                    alloc,
                    config.io,
                    sched,
                    emitter,
                );
            }

            return Runtime{
                .emitter = emitter,
                .clock = clk,
                .sched = sched,
                .threads = threads,
            };
        }

        pub fn deinit(self: *Runtime, alloc: std.mem.Allocator) void {
            for (self.threads) |*thread| {
                thread.deinit(alloc);
            }
            self.sched.deinit(alloc);

            alloc.free(self.threads);
            alloc.destroy(self.sched);
            alloc.destroy(self.clock);
            alloc.destroy(self.emitter);
        }

        pub fn run(
            self: *Runtime,
            comptime entry: anytype,
            args: anytype,
        ) anyerror!void {
            const Args = @TypeOf(args);

            const wrap = struct {
                fn inner(
                    sched: *Scheduler,
                    a: Args,
                    done: *Atomic(bool),
                ) !void {
                    // Immediately suspend the frame, returning control so we
                    // can start the scheduler and event loop.
                    suspend {
                        _ = sched.spawnInit(@frame());
                    }

                    defer {
                        assert(sched.runqueue.empty()); // no runnable tasks

                        done.store(true, .Monotonic);
                        sched.joinInit();
                    }

                    // At this point the 'init' task is running, so we can
                    // execute the entry method given to us.
                    return @call(.{}, entry, a);
                }
            }.inner;

            var done = Atomic(bool).init(false);

            // start wrapper, which immediately suspends & reschedules itself
            var frame = &async wrap(self.sched, args, &done);

            // start worker threads
            for (self.threads[1..]) |*w, i| {
                assert(w.handle == null);
                w.handle = try std.Thread.spawn(
                    .{},
                    WorkerThread.start,
                    .{ w, self, i + 1, &done },
                );
            }

            // And run the 0th worker in place
            self.threads[0].start(self, 0, &done);

            for (self.threads[1..]) |*w| {
                w.handle.?.join();
            }

            // async hygiene: match the async call above, although we know that
            // the function has returned by this point
            try nosuspend await frame;

            // Invariant checks
            assert(self.sched.runqueue.empty()); // no runnable tasks
        }

        pub fn io(self: *Runtime) *IoLoop {
            return &self.threads[threadId()].loop;
        }

        const WorkerThread = struct {
            loop: IoLoop,
            handle: ?std.Thread = null,

            fn init(
                alloc: std.mem.Allocator,
                config: IoLoop.Config,
                sched: *Scheduler,
                emitter: *Emitter,
            ) !WorkerThread {
                return WorkerThread{
                    .loop = try IoLoop.init(alloc, config, sched, emitter),
                };
            }

            fn deinit(self: *WorkerThread, alloc: std.mem.Allocator) void {
                self.loop.deinit(alloc);
            }

            fn start(
                self: *WorkerThread,
                rt: *Runtime,
                id: usize,
                done: *Atomic(bool),
            ) void {
                // setup TLS
                thread_id = id;

                rt.emitter.emit(rt.clock.now(), id, ThreadStartEvent, .{});

                // The core loop
                while (!done.load(.Monotonic)) {
                    // Check for I/O activity and timeouts
                    {
                        const tracy_zone = ztracy.ZoneNC(@src(), "I/O poll", 0x00_ff_00_00);
                        defer tracy_zone.End();

                        // TODO: poll timeout as constant
                        _ = self.loop.poll(std.time.ns_per_ms) catch |err| {
                            std.debug.panic("Runtime error: {}\n", .{err});
                        };
                    }

                    // Drive task execution in the scheduler
                    {
                        const tracy_zone = ztracy.ZoneNC(@src(), "Task exec", 0x00_00_00_ff);
                        defer tracy_zone.End();

                        _ = rt.sched.tick();
                    }
                }

                // Invariant checks
                assert(!self.loop.hasPending()); // no pending I/O operations

                rt.emitter.emit(rt.clock.now(), id, ThreadEndEvent, .{});
            }
        };
    };
}

const ScopedRegistry = EventRegistry("vx.runtime", enum {
    thread_start,
    thread_end,
});

const ThreadStartEvent = ScopedRegistry.register(.thread_start, .debug, struct {});
const ThreadEndEvent = ScopedRegistry.register(.thread_end, .debug, struct {});
