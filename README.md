# Vortex

Vortex is a Zig library for [structured
concurrency](https://en.wikipedia.org/wiki/Structured_concurrency) and
asynchronous event processing. It builds on Zig's language support for async
functions (suspend/resume and async/await), providing the user with ergonomic
task spawning, joining, cancellation, and timeouts. An included I/O engine
supports io_uring and epoll (on Linux) and kqueue (on MacOS/Darwin), with 
support for IOCP (Windows) planned.

:warning: **Disclaimer:** Vortex is a hobby project. Expect nothing to work and
everything to change.

## Getting started

Assumes you have a recent nightly build of `zig` in your path and are running
on a recent Linux or MacOS. Support for other platforms discussed below. If
you're new to Zig, see the [Zig getting started
page](https://ziglang.org/learn/getting-started/).

Run `zig build test` to run a series of unit tests. Among these unit tests,
those in `tests/` are against the public API and make for good examples. 

Run `zig build list-demos` to see a list of complete demos that use the public
API exclusively. Each can be built by `zig build <name>`. 

## A TCP Echo Server ("Hello, World")

This code shows the core of a simple TCP echo server in Vortex. The [echo
demo](demos/echo.zig) expands on this and includes a concurrent client and
server pair.

```zig
fn session(stream: *vx.TcpStream) !void {
    var buf: [128]u8 = undefined;
    while (true) {
        // await a message from the client
        const rc = try stream.recv(&buf, null);
        if (rc == 0) break; // client disconnected

        // send back what we received
        _ = try stream.send(buf[0..rc], null);
    }
}

fn start(addr: std.net.Address) !void {
    var l = try vx.net.startTcpListener(addr, 1);
    defer l.deinit();

    while (true) {
        // accept a connection on the listener
        var stream = try l.accept(null);
        defer stream.close();

        // spawn a new task for the session
        var task: vx.task.SpawnHandle(session) = undefined;
        try vx.task.spawn(&task, .{&stream}, null);

        // Wait for this session to finish. In this simple example, 
        // we only allow one client to connect at a time.
        try task.join();
    }
}

const ip4: []const u8 = "0.0.0.0";
const port: u16 = 8888;
const addr = try std.net.Address.parseIp4(ip4, port);
try vx.run(start, .{addr});
```

## Design Goals and Assumptions

- **Zero heap allocations past startup.** All structure sizes (e.g., maximum
number of tasks) are known at startup and pre-allocated. Tasks (user code) can
still perform allocations, but the runtime does not. This implies task spawning
can fail, and user code must be prepared to handle the TooManyTasks error.

- **Pluggable, cross-platform I/O engines.** The core runtime is designed around
a proactor-style I/O system, where operations are submitted, completed, and then
the runtime is notified of the completion. Reactor-style APIs (epoll, kqueue,
etc.) are supported through an adapter. 

- **Multi-threaded task execution.** The runtime launches a configurable number
of OS threads to run tasks. As of this writing, Vortex has a
resource-**inefficient** scheduler with a global queue for synchronization.
Once we have benchmarks representing something useful (e.g., a web server or
similar) then [advanced
optimizations](https://zig.news/kprotty/resource-efficient-thread-pools-with-zig-3291)
(work-stealing, wake throttling, etc.) will be explored. 

## Basic feature roadmap

- [x] Task model
  - [x] Spawning and joining
  - [x] Cancellation
- [x] I/O Engine
  - [x] kqueue (Darwin)
  - [x] epoll (Linux)
  - [x] io_uring (Linux)
  - [ ] Simulation
  - [ ] IOCP (Windows)
- [x] Timeouts
  - [x] I/O timeouts
  - [x] Task-level timeouts
  - [x] Deterministic clock & autojump testing
- [ ] Scheduler optimization
  - [x] Basic multi-threaded runtime
  - [ ] Idle thread efficiency (wait/notify)
  - [ ] Work stealing
- [ ] Demos and benchmarks
  - [x] TCP echo server
  - [x] Cancellation torture tests & fuzzing
  - [ ] HTTP server benchmark
- [ ] Observability
  - [x] Event logging
  - [ ] Metrics collection
  - [ ] Scheduler tracing
- [ ] Safety and Invariant checking
  - [ ] Orphaned tasks
  - [ ] CPU-hogging tasks
- [ ] Networking APIs
  - [x] Primitive tcp support (ipv4 only, primitive send/recv)
  - [ ] Support ipv6
  - [ ] Support udp
- [ ] File APIs
  - [ ] posix by default, backed by thread pool
  - [ ] io_uring where possible

## Longer term

Just some rough notes for now:

- **Synchronization primitives.** We can implement both an actor-style
message-passing model with *channels* between tasks and a shared-memory style
synchronization with task-aware spinlocks, barriers, etc. The core of these will
likely require a task-aware Futex-type system, where a task can wait() on a 
value and another task can wake() one or more waiters.

- **Select-ing between tasks.** We lack a way to spawn multiple tasks and cancel
all but the first one to complete. We can likely build a selection *combinator*
that launches tasks in a group and provides each task with a synchronized
cancel-peers mechanism to run on completion. 

- **Priorities and resource accounting.** In large systems, we'll likely want to
track, schedule, and budget different tasks and task groups. Consider a system
with foreground tasks that handle user requests, and background tasks that
perform system maintenance or other cleanup. We may want to prioritize
foreground tasks, until some resources run low and we need to prioritize
background tasks. How should a user express these priorities, and how will they
measure actual resource consumption to tune various policies?

- **Simulated I/O.** To facilitate deterministic testing and fault injection,
we'll want implementations of the I/O APIs that mock the OS kernel abstractions
with in-memory models.

- **Compound I/O engines.** Supporting RDMA or kernel-bypass networking (with
DPDK or similar) requires an I/O engine that can use the accelerated access
methods where possible, and fall back to conventional operations where needed. 
An I/O engine now has to juggle multiple polling APIs to reap completions and
readiness notifications across different backends. 

- **Advanced I/O offloads.** Recent versions of io_uring add support for
*automatic buffer selection*, enabling the kernel to allocate buffers at the
time an operation needs it, rather than at the time of submission. We've
structured the APIs for the I/O engine to support this and other forms of
advanced I/O offload, but some work will be required to integrate them.
