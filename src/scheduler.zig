const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const FwdIndexedList = @import("list.zig").FwdIndexedList;
const ConcurrentArrayQueue = @import("array_queue.zig").ConcurrentArrayQueue;

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

threadlocal var current_task_id: ?Task.Index = null;

const Task = struct {
    const Index = usize; // TODO trim this down?

    const State = enum {
        empty, // this task slot is available
        allocated, // this task is allocated, but not started
        runnable, // the task is ready to run
        executing, // the task is being executed currently
        suspended, // the task has suspended itself
        finished, // the task has completed

        // NOTE: cancelled is orthogonal to the scheduler state, and is kept
        // in a separate flag in the Task (below). When a task is cancelled,
        // it may still be rescheduled to perform task-specific cleanup.
    };

    id: Index,
    parent: ?Index,
    state: State,
    name: [64]u8 = undefined,
    deadline: Timespec,
    frame: ?anyframe,
    io_token: ?CancelToken,
    cancelled: bool,

    // Optional completion callback - only run if on_complete_ctx != 0
    on_complete: fn (ctx: *anyopaque, tid: Index) void = undefined,
    on_complete_ctx: Atomic(usize),

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

        pub const TaskId = Task.Index;
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
                .free = try TaskQueue.init(alloc, @intCast(u32, config.max_tasks)),
                .runqueue = try TaskQueue.init(alloc, @intCast(u32, config.max_tasks)),
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

                assert(current_task_id == null);
                current_task_id = tid;

                assert(task.frame != null);
                const toresume = task.frame.?;
                task.frame = null;

                resume toresume;

                // Beyond this resume point, we cannot set any expectations on
                // the fields in "task", as the task may have suspended itself
                // and been rescheduled on another thread already. All we can
                // reliably say here is that task 'tid' returned and that
                // current_task_id (for this worker thread) is null.

                // NOTE: the delta from start may include OS overhead to
                // reschedule the worker thread.
                const end = self.clock.now();

                // When we return back here after resuming, the task must have
                // yielded the worker thread.
                assert(current_task_id == null);

                self.emitEvent(TaskYieldEvent, .{
                    .tid = tid,
                    .delta = end - start,
                });
            }

            return count;
        }

        /// Returns the currently scheduled task id. Must be called from a
        /// task context (user code) where task id is guaranteed to be valid.
        pub fn currentTaskId(_: *Scheduler) TaskId {
            return current_task_id.?;
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

            task.io_token = op.cancelToken();

            // adjust the timeout based on task deadline
            const timeout = std.math.min(req_timeout, task.deadline);

            self.emitEvent(TaskSuspendEvent, .{ .task = task });

            suspend {
                // Now that the io_token is set, check for cancellation before
                // going async. If we are not cancelled (normal case), proceed
                // to issue the I/O operation. If we are cancelled, invoke the
                // reschedule callback as though the operation had completed,
                // as we will pick up the error at the end of this function.
                if (!task.cancelled) {
                    try op.prep(timeout, wrap, self, tid);
                } else {
                    wrap(self, tid);
                }
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
                .on_complete_ctx = Atomic(usize).init(0),
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

        /// Finishes a task
        fn finishTask(self: *Scheduler, tid: TaskId) void {
            var task = &self.tasks[tid];
            assert(task.state != .finished);

            task.state = .finished;

            // Run (optional) completion handler. We use the context as the
            // atomic flag for whether a handler is installed.
            const ctx = task.on_complete_ctx.load(.Acquire);
            if (ctx != 0) {
                task.on_complete(@intToPtr(*anyopaque, ctx), tid);
            }
        }

        /// Set up (optional) task completion handler
        fn setCompletion(
            self: *Scheduler,
            tid: TaskId,
            comptime callback: anytype,
            context: anytype,
        ) void {
            const Context = @TypeOf(context);

            const wrap = struct {
                fn inner(ptr: *anyopaque, id: TaskId) void {
                    const alignment = @typeInfo(Context).Pointer.alignment;
                    var ctx = @ptrCast(Context, @alignCast(alignment, ptr));
                    callback(ctx, id);
                }
            }.inner;

            var task = &self.tasks[tid];
            assert(task.on_complete_ctx.load(.Monotonic) == 0);

            // Ordering matters here: install the callback, then the context
            // via an atomic write that is synchronized with the Acquire in
            // finishTask()
            task.on_complete = wrap;
            task.on_complete_ctx.store(@ptrToInt(context), .Release);
        }

        /// Internal helper: returns TaskCancelled if the currently running
        /// task was cancelled, or TaskTimeout if the task is over its deadline.
        fn propagateErrors(self: *Scheduler) !void {
            const task = &self.tasks[current_task_id.?];

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
            assert(current_task_id != null);
            const tid = current_task_id.?;
            current_task_id = null;

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
            const Ptr = @TypeOf(spawnHandlePtr.*);

            // Allow passing a *?SpawnHandle as a convenience. This unwraps
            // the true Handle type.
            const Handle = switch (@typeInfo(Ptr)) {
                .Optional => @TypeOf(spawnHandlePtr.*.?),
                .Struct => Ptr,
                else => @compileError("Invalid type passed to spawn"),
            };

            // Note: the SpawnHandle is responsible for freeing the task
            // when it completes (whatever the cause).
            const tid = try self.allocTask(current_task_id.?, timeout);

            spawnHandlePtr.* = Handle{
                .sched = self,
                .tid = tid,
            };

            switch (@typeInfo(Ptr)) {
                .Optional => spawnHandlePtr.*.?.start(args),
                .Struct => spawnHandlePtr.start(args),
                else => unreachable,
            }
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
                    assert(current_task_id == tid);

                    // Ensure we return having completed this task.  We use a
                    // defer block as there are multiple return paths below
                    // (note try).
                    defer {
                        // Because the task can hit an I/O error while suspended
                        // in the scheduler, it may have already been
                        // descheduled.
                        if (current_task_id != null) {
                            _ = sched.descheduleCurrentTask(null);
                        }

                        sched.finishTask(tid);
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
                pub const JoinResult = Widen;

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

                pub fn join(self: *@This()) JoinResult {
                    assert(self.started);

                    // The task that's joining the spawned task goes async here,
                    // so we modify the scheduler state accordingly.
                    const caller = self.sched.descheduleCurrentTask(@frame());

                    // Await the result from the spawned task
                    const res = await self.frame;

                    // The spawned task is done... free the resources that
                    // were allocated in spawnTask().
                    self.sched.freeTask(self.tid);

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

        /// Waits for one of several tasks to complete, and cancels all
        /// others. Expects `spawn_handles` to be a struct with one field
        /// per task handle, and returns a tagged union of the task return
        /// types, tagged by the task that completed first.
        pub fn select(
            self: *Scheduler,
            spawn_handles: anytype,
        ) error{TaskCancelled}!SelectResultUnion(@TypeOf(spawn_handles)) {
            const SpawnHandles = @TypeOf(spawn_handles);
            const Result = SelectResultUnion(SpawnHandles);

            const CompletionCtx = struct {
                once: std.atomic.Atomic(u8),
                handles: SpawnHandles,
            };

            const fields = std.meta.fields(SpawnHandles);

            const on_complete = struct {
                fn inner(ctx: *CompletionCtx, tid: Task.Index) void {
                    // guard - only run this once
                    if (ctx.once.fetchAdd(1, .SeqCst) > 0) return;

                    // cancel all tasks that are not `tid'
                    inline for (fields) |field| {
                        const th = @field(ctx.handles, field.name);
                        if (th.tid != tid) {
                            th.cancel();
                        }
                    }
                }
            }.inner;

            var completion_ctx = CompletionCtx{
                .once = Atomic(u8).init(0),
                .handles = spawn_handles,
            };

            // 1. Install completion callback
            inline for (fields) |field| {
                const th = @field(spawn_handles, field.name);
                self.setCompletion(th.tid, on_complete, &completion_ctx);
            }

            // TODO: fairness amongst tasks that complete quickly. One way to
            // do this would be a double loop, where we capture the loop index
            // and test if index is > some random number in the range [0,
            // fields.len) in the first loop, and <= that same number in the
            // second loop. Needs a test case and a helper function to express
            // the iteration?

            // 2. Check spawned tasks for any already finished
            inline for (fields) |field| {
                const th = @field(spawn_handles, field.name);
                const task = &th.sched.tasks[th.tid];
                if (task.state == .finished) {
                    // Manually run the completion, to close race where task
                    // finishes prior to completion callback being installed.
                    // This allows us to safely join() all threads below.
                    on_complete(&completion_ctx, th.tid);
                }
            }

            // 3. Join all spawned tasks
            var res: ?Result = null;
            inline for (fields) |field| {
                const th = @field(spawn_handles, field.name);

                if (th.join()) |r| {
                    res = res orelse @unionInit(Result, field.name, r);
                } else |err| switch (err) {
                    error.TaskCancelled => {},
                    else => {
                        res = res orelse @unionInit(Result, field.name, err);
                    },
                }
            }

            return (res orelse error.TaskCancelled);
        }

        /// Reifies the return type of the select() function. Given a struct
        /// where each field is a task SpawnHandle, returns a tagged union
        /// where the Tag type is an enum of the field names and the union
        /// fields are the Task return types. Whichever task completes the
        /// select operation will become the active tag in this result.
        pub fn SelectResultUnion(comptime SpawnSet: type) type {
            const set_info = @typeInfo(SpawnSet);
            if (set_info != .Struct)
                @compileError("select() must be passed a struct");

            const fields = std.meta.fields(SpawnSet);

            const UnionField = std.builtin.Type.UnionField;
            const EnumField = std.builtin.Type.EnumField;
            var union_fields: []const UnionField = &[_]UnionField{};
            var enum_fields: []const EnumField = &[_]EnumField{};

            inline for (fields) |field, i| {
                const ti = @typeInfo(field.field_type);
                if (ti != .Pointer or ti.Pointer.size != .One)
                    @compileError("select() fields must be *SpawnHandle");

                const R = ti.Pointer.child.JoinResult;

                enum_fields = enum_fields ++ &[_]EnumField{.{
                    .name = field.name,
                    .value = i,
                }};

                union_fields = union_fields ++ &[_]UnionField{.{
                    .name = field.name,
                    .field_type = R,
                    .alignment = if (@sizeOf(R) > 0) @alignOf(R) else 0,
                }};
            }

            const enum_type = @Type(.{
                .Enum = .{
                    .layout = .Auto,
                    .tag_type = std.math.IntFittingRange(0, fields.len - 1),
                    .fields = enum_fields,
                    .decls = &.{},
                    .is_exhaustive = true,
                },
            });

            // See https://github.com/zig/ziglang/issues/8114
            const uti = .{
                .Union = .{
                    .layout = .Auto,
                    .tag_type = enum_type,
                    .fields = union_fields,
                    .decls = &.{},
                },
            };

            return @Type(uti);
        }
    };
}

const ScopedRegistry = EventRegistry("vx.sched", enum {
    thread_start,
    init_spawned,
    init_joined,
    task_suspend,
    task_resume,
    task_yield,
    task_spawned,
    task_joined,
    task_rescheduled,
    task_cancel,
    cancel_async_op,
});

const ThreadStartEvent = ScopedRegistry.register(.thread_start, .debug, struct {});
const InitSpawnedEvent = ScopedRegistry.register(.init_spawned, .debug, struct {});
const InitJoinedEvent = ScopedRegistry.register(.init_joined, .debug, struct {});
const TaskSuspendEvent = ScopedRegistry.register(.task_suspend, .debug, struct {
    task: *Task,
});
const TaskResumeEvent = ScopedRegistry.register(.task_resume, .debug, struct {
    task: *Task,
});
const TaskYieldEvent = ScopedRegistry.register(.task_yield, .debug, struct {
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

        fn on_child_complete(sched: *Scheduler, tid: Task.Index) void {
            assert(sched.tasks[tid].state == .finished);
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
            try std.testing.expect(current_task_id.? == tid);
            try std.testing.expect(task.state == .executing);

            var op = MockOp{};
            try sched.suspendTask(0, &op);

            // spawn a child task
            var ch: Scheduler.SpawnHandle(child) = undefined;
            try sched.spawnTask(&ch, .{sched}, clock.max_time);

            // install a completion handler
            sched.setCompletion(ch.tid, on_child_complete, sched);

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

fn LimitCounter(comptime T: type) type {
    return struct {
        const Self = @This();
        const Counter = T;
        const AtomicCounter = Atomic(T);

        val: AtomicCounter,
        limit: Counter,

        pub fn init(limit: Counter) Self {
            return Self{
                .val = AtomicCounter.init(0),
                .limit = limit,
            };
        }

        /// Increment counter, returning new value or null if already at limit
        pub fn inc(lc: *Self) ?Counter {
            while (true) {
                const c = lc.val.load(.Monotonic);
                if (c == lc.limit) return null;
                if (lc.tryCAS(c, c + 1)) return c + 1;
            }
        }

        /// Decrement counter, returning new value or null if already at 0
        pub fn dec(lc: *Self) ?Counter {
            while (true) {
                const c = lc.val.load(.Monotonic);
                if (c == 0) return null;
                if (lc.tryCAS(c, c - 1)) return c - 1;
            }
        }

        fn tryCAS(lc: *Self, exp: Counter, new: Counter) bool {
            return lc.val.tryCompareAndSwap(exp, new, .Release, .Monotonic) == null;
        }
    };
}

test "LimitCounter single thread" {
    var lc = LimitCounter(usize).init(2);
    try std.testing.expectEqual(@as(?usize, 1), lc.inc());
    try std.testing.expectEqual(@as(?usize, 2), lc.inc());
    try std.testing.expectEqual(@as(?usize, null), lc.inc());

    try std.testing.expectEqual(@as(?usize, 1), lc.dec());
    try std.testing.expectEqual(@as(?usize, 0), lc.dec());
    try std.testing.expectEqual(@as(?usize, null), lc.dec());
}

test "LimitCounter concurrent" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Limit = LimitCounter(usize);

    const worker = struct {
        fn run(lc: *Limit, id: usize, num_iter: usize) void {
            // even threads increment, odd decrement
            const fun = if (id % 2 == 0) Limit.inc else Limit.dec;

            var i = num_iter;
            while (i > 0) : (i -= 1) {
                while (fun(lc) == null) {
                    // not necessary, but randomizes schedule a bit
                    std.time.sleep(0);
                }
            }
        }
    }.run;

    const num_threads = 4;
    const num_iter = 1000;

    var lc = Limit.init(num_threads);

    const alloc = std.testing.allocator;
    var workers = try alloc.alloc(std.Thread, num_threads);
    defer alloc.free(workers);

    for (workers) |*w, i| {
        w.* = try std.Thread.spawn(
            .{},
            worker,
            .{ &lc, i, num_iter },
        );
    }

    for (workers) |*w| {
        w.join();
    }
}
