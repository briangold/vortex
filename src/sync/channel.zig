//! Channels are task-aware queues for communicating values from one or more
//! producers to one or more consumers. Channels are bounded in size and will
//! yield to an event loop or runtime when no space is available or no items are
//! available to push or pop, respectively.

const std = @import("std");
const builtin = @import("builtin");
const Atomic = std.atomic.Atomic;

const ConcurrentArrayQueue = @import("../array_queue.zig").ConcurrentArrayQueue;

/// Returns a Channel type holding items of type `T` and using the `Futex`
/// as an efficient waiting mechanism.
pub fn Channel(comptime T: type, comptime Futex: type) type {
    return struct {
        const Self = @This();

        // The underlying queue. The Channel implementation here relies on the
        // queue implementation using Atomic(u32) as head and tail pointers
        // coupled to the design of the queue implementation.
        queue: ConcurrentArrayQueue(T),

        /// Constructs a channel of up to `capacity` size
        pub fn init(alloc: std.mem.Allocator, capacity: u32) !Self {
            return Self{
                .queue = try ConcurrentArrayQueue(T).init(alloc, capacity),
            };
        }

        /// Frees resources allocated to the channel
        pub fn deinit(c: *Self, alloc: std.mem.Allocator) void {
            c.queue.deinit(alloc);
        }

        /// Pushes (sends) an item into the channel. If no space is available,
        /// the `Futex` mechanism yields control of the event loop or thread
        /// (depending on what Futex is used).
        pub fn push(c: *Self, item: T) !void {
            while (true) {
                if (c.queue.try_push(item)) {
                    // success - now wake a pop() waiter
                    Futex.wake(&c.queue.tail, 1);
                    return;
                } else {
                    // no space left in queue
                    try Futex.wait(
                        &c.queue.head,
                        c.queue.head.load(.Monotonic),
                        null,
                    );
                }
            }
        }

        /// Pops an item from the channel. If no items are available, the
        /// `Futex` mechanism yields control of the event loop or thread
        /// (depending on what Futex is used).
        pub fn pop(c: *Self) !T {
            while (true) {
                if (c.queue.try_pop()) |item| {
                    // success - now wake a push() waiter
                    Futex.wake(&c.queue.head, 1);
                    return item;
                } else {
                    // no items available in queue
                    try Futex.wait(
                        &c.queue.tail,
                        c.queue.tail.load(.Monotonic),
                        null,
                    );
                }
            }
        }
    };
}
