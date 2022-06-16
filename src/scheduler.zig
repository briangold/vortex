const std = @import("std");
const assert = std.debug.assert;

const FwdIndexedList = @import("list.zig").FwdIndexedList;
const ConcurrentArrayQueue = @import("sync/queue.zig").ConcurrentArrayQueue;
const LimitCounter = @import("sync/limit.zig").LimitCounter;

const clock = @import("clock.zig");
const Timespec = clock.Timespec;
const Emitter = @import("event.zig").Emitter;
const EventRegistry = @import("event.zig").EventRegistry;
const threadId = @import("runtime.zig").threadId;

const ztracy = @import("ztracy");

// The scheduler needs to serve the following workflows:
//   1 - tasks suspending for I/O operations
//   2 - tasks spawning new sub-tasks
//   3 - tasks joining their sub-tasks
//   4 - tasks canceling their sub-tasks and any pending I/O operation

pub const Config = struct {
    /// Maximum number of spawned tasks, including the init task. Must be a
    /// power-of-2.
    max_tasks: Task.Index = 128,
};

pub const DefaultScheduler = SchedulerImpl(clock.DefaultClock);
pub const SimScheduler = SchedulerImpl(clock.SimClock);

/// Interface for triggering an I/O cancellation. Implementations must provide
/// a "cancel" method that represents an attempt at canceling a pending I/O
/// operation that may still be outstanding. The caller cannot assume that
/// the I/O will be cancelled in all cases. The platform implementing this
/// cancellation must guarantee that the cancelled task will be resumed as
/// part of either this cancellation or the I/O operation completing.
pub const CancelToken = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        cancel: fn (ptr: *anyopaque) void,
    };

    pub fn init(
        pointer: anytype,
        comptime cancelFn: fn (@TypeOf(pointer)) void,
    ) CancelToken {
        const Ptr = @TypeOf(pointer);
        const ptr_info = @typeInfo(Ptr);

        assert(ptr_info == .Pointer); // Must be a pointer
        assert(ptr_info.Pointer.size == .One); // Must be a single-item pointer

        const alignment = ptr_info.Pointer.alignment;

        const gen = struct {
            fn cancelImpl(ptr: *anyopaque) void {
                const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
                return @call(.{ .modifier = .always_inline }, cancelFn, .{self});
            }

            const vtable = VTable{
                .cancel = cancelImpl,
            };
        };

        return CancelToken{
            .ptr = pointer,
            .vtable = &gen.vtable,
        };
    }

    pub inline fn cancel(self: CancelToken) void {
        return self.vtable.cancel(self.ptr);
    }
};

threadlocal var currentTaskId: ?Task.Index = null;

const Task = struct {
    const Index = usize; // TODO trim this down?

    const State = enum {
        empty, // this task slot is available
        allocated, // this task is allocated, but not started
        runnable, // the task is ready to run
        executing, // the task is being executed currently
        suspended, // the task has suspended itself
    };

    id: Index,
    parent: ?Index,
    state: State,
    name: [64]u8 = undefined,
    deadline: Timespec,
    frame: ?anyframe,
    io_token: ?CancelToken,
    cancelled: bool,

    next: ?Index, // link for free/run list
    sibling: ?Index, // link for children of a given parent

    pub fn format(
        self: Task,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{d}", .{self.id});

        if (self.deadline == clock.max_time) {
            try writer.writeAll(" deadline=inf");
        } else {
            try writer.print(" deadline={d}", .{self.deadline});
        }

        try writer.print(" state={s}", .{@tagName(self.state)});
    }
};

fn SchedulerImpl(comptime C: type) type {
    return struct {
        const Scheduler = @This();

        pub const Clock = C;

        const TaskId = Task.Index;
        const TaskList = FwdIndexedList(Task, .next);
        const SiblingList = FwdIndexedList(Task, .sibling);
        const TaskQueue = ConcurrentArrayQueue(TaskId);

        const TaskTreeNode = struct {
            children: SiblingList,

            // The mutex here prevents concurrent updates to a task's children
            // while it is being cancelled. We don't need to optimize
            // cancellation for performance, hence a mutex is preferred over
            // more complex schemes.
            mutex: std.Thread.Mutex,
        };

        clock: *Clock,
        emitter: *Emitter,
        admit: LimitCounter(usize),
        tasks: []Task,
        taskTree: []TaskTreeNode,
        free: TaskQueue,
        runqueue: TaskQueue,

        /// Initializes a Scheduler object. Use deinit(alloc) to uninitialize.
        pub fn init(
            alloc: std.mem.Allocator,
            clk: *Clock,
            emitter: *Emitter,
            config: Config,
        ) !Scheduler {
            assert(std.math.isPowerOfTwo(config.max_tasks));
            var tasks = try alloc.alloc(Task, config.max_tasks);
            var taskTree = try alloc.alloc(TaskTreeNode, config.max_tasks);

            var self = Scheduler{
                .clock = clk,
                .emitter = emitter,
                .admit = LimitCounter(usize).init(config.max_tasks),
                .tasks = tasks,
                .taskTree = taskTree,
                .free = try TaskQueue.init(alloc, config.max_tasks),
                .runqueue = try TaskQueue.init(alloc, config.max_tasks),
            };

            var idx: Task.Index = 0;
            while (idx < config.max_tasks) : (idx += 1) {
                self.free.push(idx);
                self.taskTree[idx] = TaskTreeNode{
                    .children = SiblingList.init(self.tasks),
                    .mutex = std.Thread.Mutex{},
                };
            }

            return self;
        }

        pub fn deinit(self: *Scheduler, alloc: std.mem.Allocator) void {
            self.runqueue.deinit(alloc);
            self.free.deinit(alloc);
            alloc.free(self.tasks);
            alloc.free(self.taskTree);
        }

        /// Drives execution of runnable tasks. Returns the number of tasks that
        /// were advanced during this call.
        /// TODO: pass in some kind of time budget? Currently runs all runnable
        /// tasks.
        pub fn tick(self: *Scheduler) usize {
            var count: usize = 0;

            while (self.runqueue.try_pop()) |tid| : (count += 1) {
                // Mark the start of a task fragment.
                const start = self.clock.now();

                var task = &self.tasks[tid];

                self.emitEvent(TaskResumeEvent, .{ .task = task });
                ztracy.FiberEnter(@ptrCast([*:0]const u8, &task.name[0]));

                assert(task.state == .runnable);
                task.state = .executing;

                assert(currentTaskId == null);
                currentTaskId = tid;

                assert(task.frame != null);
                const toresume = task.frame.?;
                task.frame = null;

                resume toresume;

                // Beyond this resume point, we cannot set any expectations on
                // the fields in "task", as the task may have suspended itself
                // and been rescheduled on another thread already. All we can
                // reliably say here is that task 'tid' returned and that
                // currentTaskId (for this worker thread) is null.

                // NOTE: the delta from start may include OS overhead to
                // reschedule the worker thread.
                const end = self.clock.now();

                // When we return back here after resuming, the task must have
                // yielded the worker thread.
                assert(currentTaskId == null);

                self.emitEvent(TaskReturnEvent, .{
                    .tid = tid,
                    .delta = end - start,
                });
            }

            return count;
        }

        /// Spawns the special 'init' task. To be run inside a suspend block,
        /// allowing the scheduler to set up the task structures and schedule
        /// init like any other task.
        pub fn spawnInit(self: *Scheduler, frame: anyframe) TaskId {
            const tid = self.allocTask(
                null,
                clock.max_time,
            ) catch @panic("Cannot spawn init");

            self.startTask(tid, frame);

            self.emitEvent(InitSpawnedEvent, .{});

            return tid;
        }

        /// Called before exiting the init task, allowing the scheduler
        /// invariant checking to succeed one last time.
        pub fn joinInit(self: *Scheduler) void {
            const tid = self.descheduleCurrentTask(null);
            self.freeTask(tid);

            self.emitEvent(InitJoinedEvent, .{});
        }

        pub const SuspendError = error{
            TaskTimeout,
            TaskCancelled,
        } || anyerror; // TODO: unify/narrow

        /// Suspends the current task, to be resumed by an event submitted to
        /// the event loop.
        pub fn suspendTask(
            self: *Scheduler,
            req_timeout: Timespec,
            op: anytype,
        ) SuspendError!void {
            const wrap = struct {
                fn inner(ctx: *anyopaque, data: usize) void {
                    const ptr_info = @typeInfo(*Scheduler);
                    const alignment = ptr_info.Pointer.alignment;
                    var bind = @ptrCast(*Scheduler, @alignCast(alignment, ctx));

                    return @call(
                        .{ .modifier = .always_inline },
                        rescheduleTask,
                        .{ bind, data },
                    );
                }
            }.inner;

            const tid = self.descheduleCurrentTask(@frame());
            var task = &self.tasks[tid];

            // adjust the timeout based on task deadline
            const timeout = std.math.min(req_timeout, task.deadline);

            task.io_token = op.cancelToken();

            suspend {
                try op.prep(timeout, wrap, self, tid);
            }

            task.io_token = null;

            // propagate scheduler-enforced errors back to trigger cleanup
            return self.propagateErrors();
        }

        /// Allocates a new task entry and returns the task id. The task entry
        /// is not added to any scheduling lists at this point.
        fn allocTask(
            self: *Scheduler,
            parent: ?TaskId,
            timeout: Timespec,
        ) !TaskId {
            // Admission control: ensure we have fewer than max tasks
            if (self.admit.inc() == null)
                return error.TooManyTasks;

            // We are guaranteed to succeed with getting a tid, so we use the
            // blocking pop() here. See the comments in the queue implementation
            // for scenarios where blocking can occur. It should be rare.
            const tid = self.free.pop();

            var task = &self.tasks[tid];
            task.* = Task{
                .id = tid,
                .parent = parent,
                .state = .allocated,
                .deadline = self.clock.now() +| timeout,
                .cancelled = false,
                .frame = null,
                .io_token = null,
                .next = null,
                .sibling = null,
            };

            _ = std.fmt.bufPrintZ(&task.name, "task-{d}", .{tid}) catch
                @panic("task name too long");

            // add the new task to the parent's list of child tasks
            if (parent) |pt| {
                const node = &self.taskTree[pt];
                node.mutex.lock();
                defer node.mutex.unlock();

                node.children.push(tid);
            }

            return tid;
        }

        /// Deallocates the task entry for a completed task.
        fn freeTask(self: *Scheduler, tid: TaskId) void {
            var task = &self.tasks[tid];

            // ok to run this read only operation outside mutex b/c tid no
            // longer running, and cannot spawn concurrently
            assert(self.taskTree[tid].children.peek() == null); // cannot have children

            if (task.parent) |parent| {
                // remove this task from its parents' list of children
                const node = &self.taskTree[parent];
                node.mutex.lock();
                defer node.mutex.unlock();

                if (!node.children.unlink(tid)) unreachable;
            }

            task.state = .empty;
            self.free.push(tid);

            // Admission control
            if (self.admit.dec() == null)
                @panic("Underflow on task count");
        }

        /// Sets up task `tid' to run from `frame'
        fn startTask(self: *Scheduler, tid: TaskId, frame: anyframe) void {
            var task = &self.tasks[tid];
            assert(task.state == .allocated);

            task.state = .runnable;
            task.frame = frame;
            self.runqueue.push(tid);
        }

        /// Internal helper: returns TaskCancelled if the currently running
        /// task was cancelled, or TaskTimeout if the task is over its deadline.
        fn propagateErrors(self: *Scheduler) !void {
            const task = &self.tasks[currentTaskId.?];

            // Cancellation takes precendence
            if (task.cancelled) {
                return error.TaskCancelled;
            }

            // But we check for timeouts as well
            if (self.clock.now() >= task.deadline) {
                return error.TaskTimeout;
            }
        }

        /// Update scheduler structures prior to suspension. This is used to
        /// centralize scheduler updates from either I/O suspension or
        /// task-spawning suspension points. The caller is responsible for the
        /// actual suspend operation (either an explicit suspend or an await).
        /// Returns the id of the suspended task.
        fn descheduleCurrentTask(self: *Scheduler, frame: ?anyframe) TaskId {
            assert(currentTaskId != null);
            const tid = currentTaskId.?;
            currentTaskId = null;

            ztracy.FiberLeave();

            var task = &self.tasks[tid];
            assert(task.state == .executing);
            task.state = .suspended;

            assert(task.frame == null);
            task.frame = frame;

            return tid;
        }

        /// Reschedules a suspended task `tid'. This function is intended to be
        /// used as a callback from an I/O system when an operation issued by
        /// this task completes. It's also used in the SpawnHandle logic to
        /// reschedule the caller of join().
        ///
        /// Note: when used as a callback for I/O, runs in the I/O thread
        /// context. When called from join(), runs in the task thread context.
        /// We may specialize this later to enqueue on different run queues
        /// to avoid contention and bias load balancing.
        fn rescheduleTask(self: *Scheduler, tid: TaskId) void {
            var task = &self.tasks[tid];
            assert(task.state == .suspended);
            assert(task.frame != null);

            self.emitEvent(TaskRescheduledEvent, .{ .task = task });

            task.state = .runnable;
            self.runqueue.push(tid);
        }

        /// Cancels task `tid'. If suspended for I/O operation, calls into
        /// EventLoop to cancel pending operation.
        fn cancelTask(self: *Scheduler, tid: TaskId) void {
            var task = &self.tasks[tid];

            self.emitEvent(TaskCancelEvent, .{ .task = task });

            // recursive walk over taskTree to cancel children
            {
                const node = &self.taskTree[tid];
                node.mutex.lock();
                defer node.mutex.unlock();

                var it = node.children.iter();
                while (it.get()) |idx| : (_ = it.next()) {
                    self.cancelTask(idx);
                }
            }

            // Cancel any asynchronous operations.
            if (task.io_token) |token| {
                self.emitEvent(CancelAsyncOpEvent, .{ .task = task });
                token.cancel();
            }

            // now mark the task as cancelled
            task.cancelled = true;
        }

        pub fn SpawnHandle(comptime entry: anytype) type {
            return SpawnHandleImpl(Scheduler, entry);
        }

        pub const SpawnError = error{TooManyTasks};

        pub fn spawnTask(
            self: *Scheduler,
            spawnHandlePtr: anytype,
            args: anytype,
            timeout: Timespec,
        ) SpawnError!void {
            // Handle will be a type returned by SpawnHandle, which a caller
            // must instantiate first to get the async frame on its stack. The
            // intended usage for this API is to first create an undefined
            // SpawnHandle, then pass that variable's location here for
            // initialization. With improvements in RLS we can likely improve
            // the ergonomics.
            const Handle = @TypeOf(spawnHandlePtr.*);

            // Note: the SpawnHandle is responsible for freeing the task
            // when it completes (whatever the cause).
            const tid = try self.allocTask(currentTaskId.?, timeout);

            spawnHandlePtr.* = Handle{
                .sched = self,
                .tid = tid,
            };
            spawnHandlePtr.start(args);
        }

        fn SpawnHandleImpl(
            comptime Sched: anytype,
            comptime entry: anytype,
        ) type {
            const Result = FnReturn(entry);
            const Widen = WidenErrorUnion(Result, anyerror);

            // The signature of `launch' cannot be generic as we call
            // @Frame(launch) to get the stack frame location. Fortunately
            // there's a nice type- generator to return a tuple from a function
            // signature.
            const Args = std.meta.ArgsTuple(@TypeOf(entry));

            // Our asynchronous function to be invoked by the Spawner.start
            // method.  This is responsible for arranging the runtime scheduler
            // state for itself and, upon resuming, calling the actual entry
            // method.  NOTE: the use of Widen as return type is due to a
            // segfault in the zig compiler. It appears to choke on
            // peer-type-resolution when entry has an inferred error set. Using
            // WidenErrorUnion to fuse in anyerror resolves the issue with no
            // runtime cost.
            const launch = struct {
                fn inner(sched: *Sched, tid: Sched.TaskId, args: Args) Widen {
                    // suspend here and schedule the new task to start
                    suspend {
                        sched.startTask(tid, @frame());
                    }

                    // now running as spawned task
                    assert(currentTaskId == tid);

                    // Ensure we return having completed this task.  We use a
                    // defer block as there are multiple return paths below
                    // (note try).
                    defer {
                        // Because the task can hit an I/O error while suspended
                        // in the scheduler, it may have already been
                        // descheduled.
                        if (currentTaskId != null) {
                            _ = sched.descheduleCurrentTask(null);
                        }

                        // the spawned task is done... free the resources that
                        // were allocated in the SpawnHandle start() method.
                        sched.freeTask(tid);
                    }

                    // If the spawned task was cancelled or timed out before it
                    // started, just propagate the appropriate error back before
                    // entry. There can't be any task-specific cleanup to run if
                    // it never started.
                    try sched.propagateErrors();

                    return @call(.{}, entry, args);
                }
            }.inner;

            return struct {
                const Frame = @Frame(launch);

                started: bool = false,
                frame: Frame = undefined,
                sched: *Sched,
                tid: Sched.TaskId,

                // Implementation NOTE: at the time of writing, functions cannot
                // refer to local stack locations safely. This prevents us from
                // combining init() and start() into a single method, as we need
                // to ensure the caller's stack is being used to store Spawner
                // object and its internal frame. See
                // https://github.com/ziglang/zig/issues/7769
                //
                // Once #7769 is resolved, we may be able to simplify the API
                // here into starting the launch fn from init. For the time
                // being, the guard flag 'started' checks that a Spawner is
                // started exactly once.

                fn start(self: *@This(), args: anytype) void {
                    assert(!self.started);
                    self.started = true;

                    // Start the async function. Note that it will start
                    // immediately as though a direct (normal) function call was
                    // made. Thus launch has a suspend block at the beginning to
                    // yield back.

                    // To support passing in a convenient, anonymous struct
                    // tuple in args, we use coerceAnonStruct to coerce that
                    // into Args, which is type-generated by ArgsTuple.  This
                    // seems like the sort of thing the compiler should be able
                    // to auto-coerce for us, but it doesn't as of this writing.
                    _ = @asyncCall(
                        &self.frame,
                        {},
                        launch,
                        .{ self.sched, self.tid, coerceAnonStruct(Args, args) },
                    );

                    self.sched.emitEvent(
                        TaskSpawnedEvent,
                        .{ .task = &self.sched.tasks[self.tid] },
                    );
                }

                /// Cancel this task by its handle. Note that cancellation does
                /// not wait for the task to complete. In most code, a task
                /// spawn will have a paired join() in a defer block, and we
                /// want that join to still run.
                pub fn cancel(self: *@This()) void {
                    assert(self.started);

                    // Trigger cancellation of the spawned task and all its
                    // children.
                    self.sched.cancelTask(self.tid);
                }

                pub fn join(self: *@This()) Widen {
                    assert(self.started);

                    // The task that's joining the spawned task goes async here,
                    // so we modify the scheduler state accordingly.
                    const caller = self.sched.descheduleCurrentTask(@frame());

                    // Await the result from the spawned task
                    const res = await self.frame;

                    // Take another trip through the scheduler. We could
                    // directly manipulate the scheduler state to put the caller
                    // into the 'executing' state, but (a) this could hog the
                    // loop and (b) we want to centralize where scheduler
                    // manipulations are made to simplify how cancellation and
                    // invariant-checking are handled.

                    suspend {
                        self.sched.rescheduleTask(caller);
                    }

                    self.sched.emitEvent(
                        TaskJoinedEvent,
                        .{ .task = &self.sched.tasks[self.tid] },
                    );

                    // Because we've gone async, check to see if the caller has
                    // cancelled or exceeded its deadline, and propagate that
                    // error back up. Note: this is a great test coverage
                    // exercise.
                    try self.sched.propagateErrors();

                    return res;
                }
            };
        }

        /// Take an ErrorUnion type (EU) and an ErrorSet (err) and merge the
        /// additional errors in err into the error_set in EU. Note: this code
        /// is not specific to Scheduler and could be extracted for general use.
        fn WidenErrorUnion(comptime EU: anytype, comptime err: anytype) type {
            switch (@typeInfo(EU)) {
                .ErrorUnion => |u| {
                    const info = std.builtin.TypeInfo{
                        .ErrorUnion = .{
                            .error_set = u.error_set || err,
                            .payload = u.payload,
                        },
                    };
                    return @Type(info);
                },
                else => @panic("expected ErrorUnion in WidenError"),
            }
        }

        /// Get the return type of a function.
        /// Note: could extract for general use.
        fn FnReturn(comptime function: anytype) type {
            const info = @typeInfo(@TypeOf(function));
            if (info != .Fn) @compileError("expecting a function type");

            const function_info = info.Fn;
            assert(function_info.return_type != null);
            return function_info.return_type.?;
        }

        /// Internal helper to coerce an anonymous struct 'from' to another
        /// struct of type R that has the same fields.
        fn coerceAnonStruct(comptime R: type, from: anytype) R {
            var result: R = undefined;
            const RF = std.meta.fields(R);
            const FF = std.meta.fields(@TypeOf(from));
            if (RF.len != FF.len)
                @compileError("Mismatched anonymous struct fields");

            inline for (RF) |f| {
                // NOTE: assignment also ensures safe coercion
                @field(result, f.name) = @field(from, f.name);
            }
            return result;
        }

        fn emitEvent(
            self: *Scheduler,
            comptime Event: type,
            user: Event.User,
        ) void {
            self.emitter.emit(self.clock.now(), threadId(), Event, user);
        }
    };
}

const ScopedRegistry = EventRegistry("vx.sched", enum {
    thread_start,
    init_spawned,
    init_joined,
    task_resume,
    task_return,
    task_spawned,
    task_joined,
    task_rescheduled,
    task_cancel,
    cancel_async_op,
});

const ThreadStartEvent = ScopedRegistry.register(.thread_start, .debug, struct {});
const InitSpawnedEvent = ScopedRegistry.register(.init_spawned, .debug, struct {});
const InitJoinedEvent = ScopedRegistry.register(.init_joined, .debug, struct {});
const TaskResumeEvent = ScopedRegistry.register(.task_resume, .debug, struct {
    task: *Task,
});
const TaskReturnEvent = ScopedRegistry.register(.task_return, .debug, struct {
    tid: Task.Index,
    delta: Timespec,
});
const TaskSpawnedEvent = ScopedRegistry.register(.task_spawned, .debug, struct {
    task: *Task,
});
const TaskJoinedEvent = ScopedRegistry.register(.task_joined, .debug, struct {
    task: *Task,
});
const TaskRescheduledEvent = ScopedRegistry.register(.task_rescheduled, .debug, struct {
    task: *Task,
});
const TaskCancelEvent = ScopedRegistry.register(.task_cancel, .debug, struct {
    task: *Task,
});
const CancelAsyncOpEvent = ScopedRegistry.register(.cancel_async_op, .debug, struct {
    task: *Task,
});

test "Scheduler unit" {
    const alloc = std.testing.allocator;
    const eventlib = @import("event.zig");
    const Clock = clock.SimClock;
    const Scheduler = SchedulerImpl(Clock);

    const MockOp = struct {
        started: bool = false,

        fn prep(
            op: *@This(),
            _: Timespec,
            comptime callback: anytype,
            callback_ctx: anytype,
            callback_data: usize,
        ) !void {
            op.started = true;
            callback(callback_ctx, callback_data);
        }

        fn cancel(_: *@This()) void {}

        fn cancelToken(op: *@This()) CancelToken {
            return CancelToken.init(op, cancel);
        }
    };

    const InitTask = struct {
        fn child(_: *Scheduler) !void {
            // do nothing
        }

        fn asyncChild(sched: *Scheduler) !void {
            var op = MockOp{};
            try sched.suspendTask(0, &op);
        }

        fn start(_: *@This(), sched: *Scheduler) !void {
            var tid: Task.Index = undefined;

            suspend {
                tid = sched.spawnInit(@frame());
            }

            defer sched.joinInit();

            // simple validations of our now-running init task
            const task = &sched.tasks[tid];
            try std.testing.expect(currentTaskId.? == tid);
            try std.testing.expect(task.state == .executing);

            var op = MockOp{};
            try sched.suspendTask(0, &op);

            // spawn a child task
            var ch: Scheduler.SpawnHandle(child) = undefined;
            try sched.spawnTask(&ch, .{sched}, clock.max_time);

            // wait for the child to complete
            try ch.join();

            // spawn another child task to be cancelled
            try sched.spawnTask(&ch, .{sched}, clock.max_time);

            // cancel the child
            ch.cancel();
            ch.join() catch |err| switch (err) {
                error.TaskCancelled => {}, // we know
                else => return err,
            };

            // spawn a child that runs an async operation
            var ach: Scheduler.SpawnHandle(asyncChild) = undefined;
            try sched.spawnTask(&ach, .{sched}, clock.max_time);

            // wait for the child to complete
            try ach.join();

            // spawn another asyncChild task to be cancelled
            try sched.spawnTask(&ach, .{sched}, clock.max_time);

            // suspend-then-resume to let child run
            _ = sched.descheduleCurrentTask(@frame());
            suspend {
                sched.rescheduleTask(tid);
            }

            // cancel the child
            ach.cancel();
            ach.join() catch |err| switch (err) {
                error.TaskCancelled => {}, // we know
                else => return err,
            };
        }
    };

    var clk = Clock{};

    const sync_writer = eventlib.SyncEventWriter{
        .writer = std.io.getStdErr().writer(),
        .mutex = std.debug.getStderrMutex(),
    };

    var emitter = Emitter.init(.info, sync_writer);

    var sched = try Scheduler.init(alloc, &clk, &emitter, .{ .max_tasks = 2 });
    defer sched.deinit(alloc);

    // Launch our init function. It will immediate suspend after creating
    // the task and scheduling itself.
    var init_task = InitTask{};
    var frame = &async init_task.start(&sched);

    // The scheduler loop should have 13 task wakeups to execute
    //   1 - Task 0 (init) gets started
    //   2 - Task 0 (init) gets rescheduled by simulated I/O
    //   3 - Task 1 (child) gets started
    //   4 - Task 0 (init) gets rescheduled by join-ing child
    //   5 - Task 1 (child) gets started, then cancelled
    //   6 - Task 0 (init) gets rescheduled by cancel-ing child
    //   7 - Task 1 (asyncChild) gets started
    //   8 - Task 1 (asyncChild) gets rescheduled by simulated I/O
    //   9 - Task 0 (init) gets rescheduled by join-ing asyncChild
    //  10 - Task 1 (asyncChild) gets started
    //  11 - Task 0 (init) gets rescheduled
    //  12 - Task 1 (asyncChild) gets rescheduled
    //  13 - Task 0 (init) gets rescheduled, cancels child

    try std.testing.expectEqual(@as(usize, 13), sched.tick());

    // The scheduler loop should have no tasks to execute
    try std.testing.expectEqual(@as(usize, 0), sched.tick());

    // The init task should be finished at this point
    try nosuspend await frame;
}
