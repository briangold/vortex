//! A concurrent, bounded queue backed by an array. Yields the task/thread
//! using `Futex`.
const std = @import("std");
const builtin = @import("builtin");
const Atomic = std.atomic.Atomic;

const RawArrayQueue = @import("raw_array_queue.zig").ConcurrentArrayQueue;

pub fn ArrayQueue(comptime T: type, comptime Futex: type) type {
    return struct {
        const Queue = @This();
        const RawQueue = RawArrayQueue(T);

        array: RawQueue,
        slots_avail: Atomic(u32), // free slots available for push
        items_avail: Atomic(u32), // items available to pop

        pub fn init(alloc: std.mem.Allocator, capacity: u32) !Queue {
            return Queue{
                .array = try RawQueue.init(alloc, capacity),
                .slots_avail = Atomic(u32).init(capacity),
                .items_avail = Atomic(u32).init(0),
            };
        }

        pub fn deinit(q: *Queue, alloc: std.mem.Allocator) void {
            q.array.deinit(alloc);
        }

        pub fn push(q: *Queue, item: T) !void {
            while (true) {
                // fast-path: non-blocking push
                if (q.try_push(item)) return;

                // slow-path: wait for slots_avail to become non-zero, then
                // loop around again, relying on Futex to keep waitlist
                try Futex.wait(&q.slots_avail, 0, null);
            }
        }

        pub fn pop(q: *Queue) !T {
            while (true) {
                // fast-path: non-blocking pop
                if (q.try_pop()) |item| return item;

                // slow-path: wait for items_avail to become non-zero, then
                // loop around again, relying on Futex to keep waitlist
                try Futex.wait(&q.items_avail, 0, null);
            }
        }

        pub fn try_push(q: *Queue, item: T) bool {
            if (q.array.try_push(item)) {
                // push success: one fewer slot, one more item
                _ = q.slots_avail.fetchSub(1, .Monotonic);
                _ = q.items_avail.fetchAdd(1, .Monotonic);

                // wake unconditionally - wake() maintains the list of pending
                // waiters and should efficiently know if zero are waiting
                Futex.wake(&q.items_avail, 1);

                return true;
            }

            return false;
        }

        pub fn try_pop(q: *Queue) ?T {
            if (q.array.try_pop()) |item| {
                // pop success: one fewer item, one more slot
                _ = q.items_avail.fetchSub(1, .Monotonic);
                _ = q.slots_avail.fetchAdd(1, .Monotonic);

                // wake unconditionally - wake() maintains the list of pending
                // waiters and should efficiently know if zero are waiting
                Futex.wake(&q.slots_avail, 1);

                return item;
            }

            return null;
        }
    };
}
