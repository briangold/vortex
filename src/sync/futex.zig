//! Task-aware Futex primitive. Uses similar API to std.Thread.Futex, but
//! waiting results in a test being suspended within Vortex. Implementation
//! is copied with minimal changes from std.Thread.Futex.PosixFutex (MIT).
//! Uses a platform-specific FutexEvent mechanism to implement the wait and
//! notification.

const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const Mutex = std.Thread.Mutex;
const Treap = std.Treap(usize, std.math.order);

const clock = @import("../clock.zig");
const Timespec = clock.Timespec;
const max_time = clock.max_time;

pub fn Futex(comptime Runtime: type) type {
    const FutexEvent = Runtime.IoLoop.FutexEvent;

    return struct {
        /// Checks if `ptr` still contains the value `expect` and, if so, blocks
        /// the caller until:
        /// - The value at `ptr` is no longer equal to `expect`.
        /// - The caller is unblocked by a matching `wake()`.
        /// - The caller is unblocked spuriously ("at random").
        ///
        /// The checking of `ptr` and `expect`, along with blocking the caller,
        /// is done atomically and totally ordered (sequentially consistent)
        /// with respect to other wait()/wake() calls on the same `ptr`.
        pub fn wait(
            rt: *Runtime,
            ptr: *const Atomic(u32),
            expect: u32,
            maybe_interval: ?Timespec,
        ) !void {
            const address = Address.from(ptr);
            const bucket = Bucket.from(address);

            // Announce that there's a waiter in the bucket before checking the
            // ptr/expect condition. If the announcement is reordered after the ptr
            // check, the waiter could deadlock:
            //
            // - T1: checks ptr == expect which is true
            // - T2: updates ptr to != expect
            // - T2: does Futex.wake(), sees no pending waiters, exits
            // - T1: bumps pending waiters (was reordered after the ptr == expect check)
            // - T1: goes to sleep and misses both the ptr change and T2's wake up
            //
            // SeqCst as Acquire barrier to ensure the announcement happens before
            // the ptr check below. SeqCst as shared modification order to form a
            // happens-before edge with the fence(.SeqCst)+load() in wake().
            var pending = bucket.pending.fetchAdd(1, .SeqCst);
            assert(pending < std.math.maxInt(usize));

            // If the wait gets cancelled, remove the pending count we previously
            // added. This is done outside the mutex lock to keep the critical
            // section short in case of contention.
            var cancelled = false;
            defer if (cancelled) {
                pending = bucket.pending.fetchSub(1, .Monotonic);
                assert(pending > 0);
            };

            const interval = maybe_interval orelse max_time;
            var waiter: Waiter = undefined;
            {
                bucket.mutex.lock();
                defer bucket.mutex.unlock();

                cancelled = ptr.load(.Monotonic) != expect;
                if (cancelled) {
                    return;
                }

                waiter.event = FutexEvent.init(rt.io());
                WaitQueue.insert(&bucket.treap, address, &waiter);
            }

            // start waiting
            waiter.event.wait(interval) catch {
                {
                    bucket.mutex.lock();
                    defer bucket.mutex.unlock();

                    cancelled = WaitQueue.tryRemove(&bucket.treap, address, &waiter);
                }

                if (cancelled) {
                    return error.Timeout;
                } else {
                    // If we fail to cancel after a timeout, it means a waker task
                    // dequeued us and will wake us up.  We must wait until the
                    // event is canceled as that's a signal that the waker wont
                    // access the waiter memory anymore. If we return early without
                    // waiting, the waiter on the stack would be invalidated and the
                    // waker task risks a UAF.
                    waiter.event.wait(null) catch unreachable;
                }
            };
        }

        /// Unblocks at most `max_waiters` blocked in a `wait()` call on `ptr`.
        pub fn wake(rt: *Runtime, ptr: *const Atomic(u32), max_waiters: usize) void {
            _ = rt;

            const address = Address.from(ptr);
            const bucket = Bucket.from(address);

            // Quick check if there's even anything to wake up.
            // The change to the ptr's value must happen before we check for
            // pending waiters. If not, the wake() thread could miss a sleeping
            // waiter and have it deadlock:
            //
            // - T2: p = has pending waiters (reordered before the ptr update)
            // - T1: bump pending waiters
            // - T1: if ptr == expected: sleep()
            // - T2: update ptr != expected
            // - T2: p is false from earlier so doesn't wake (T1 missed ptr update and T2 missed T1 sleeping)
            //
            // What we really want here is a Release load, but that doesn't
            // exist under the C11 memory model.  We could instead do
            // `bucket.pending.fetchAdd(0, Release) == 0` which achieves
            // effectively the same thing, but the RMW operation unconditionally
            // marks the cache-line as modified for others causing unnecessary
            // fetching/contention.
            //
            // Instead we opt to do a full-fence + load instead which avoids
            // taking ownership of the cache-line.  fence(SeqCst) effectively
            // converts the ptr update to SeqCst and the pending load to SeqCst:
            // creating a Store-Load barrier.
            //
            // The pending count increment in wait() must also now use SeqCst
            // for the update + this pending load to be in the same modification
            // order as our load isn't using Release/Acquire to guarantee it.
            bucket.pending.fence(.SeqCst);
            if (bucket.pending.load(.Monotonic) == 0) {
                return;
            }

            // Keep a list of all the waiters notified and wake then up
            // outside the mutex critical section.
            var notified = WaitList{};
            defer if (notified.len > 0) {
                const pending = bucket.pending.fetchSub(notified.len, .Monotonic);
                assert(pending >= notified.len);

                while (notified.pop()) |waiter| {
                    assert(!waiter.is_queued);
                    waiter.event.notify();
                }
            };

            bucket.mutex.lock();
            defer bucket.mutex.unlock();

            // Another pending check again to avoid the WaitQueue lookup if
            // not necessary.
            if (bucket.pending.load(.Monotonic) > 0) {
                notified = WaitQueue.remove(&bucket.treap, address, max_waiters);
            }
        }

        const Bucket = struct {
            mutex: Mutex align(std.atomic.cache_line) = .{},
            pending: Atomic(usize) = Atomic(usize).init(0),
            treap: Treap = .{},

            // Global array of buckets that addresses map to.
            // Bucket array size is pretty much arbitrary here, but it must be a power
            // of two for fibonacci hashing.
            var buckets = [_]Bucket{.{}} ** @bitSizeOf(usize);

            // https://github.com/Amanieu/parking_lot/blob/1cf12744d097233316afa6c8b7d37389e4211756/core/src/parking_lot.rs#L343-L353
            fn from(address: usize) *Bucket {
                // The upper `@bitSizeOf(usize)` bits of the fibonacci golden ratio.
                // Hashing this via (h * k) >> (64 - b) where k=golden-ration and
                // b=bitsize-of-array evenly lays out h=hash values over the bit range
                // even when the hash has poor entropy (identity-hash for pointers).
                const max_multiplier_bits = @bitSizeOf(usize);
                const fibonacci_multiplier = 0x9E3779B97F4A7C15 >> (64 - max_multiplier_bits);

                const max_bucket_bits = @ctz(usize, buckets.len);
                comptime assert(std.math.isPowerOfTwo(buckets.len));

                const index = (address *% fibonacci_multiplier) >> (max_multiplier_bits - max_bucket_bits);
                return &buckets[index];
            }
        };

        const Address = struct {
            fn from(ptr: *const Atomic(u32)) usize {
                // Get the alignment of the pointer.
                const alignment = @alignOf(Atomic(u32));
                comptime assert(std.math.isPowerOfTwo(alignment));

                // Make sure the pointer is aligned,
                // then cut off the zero bits from the alignment to get the unique address.
                const addr = @ptrToInt(ptr);
                assert(addr & (alignment - 1) == 0);
                return addr >> @ctz(usize, alignment);
            }
        };

        const Waiter = struct {
            node: Treap.Node,
            prev: ?*Waiter,
            next: ?*Waiter,
            tail: ?*Waiter,
            is_queued: bool,
            event: FutexEvent,
        };

        // An unordered set of Waiters
        const WaitList = struct {
            top: ?*Waiter = null,
            len: usize = 0,

            fn push(self: *WaitList, waiter: *Waiter) void {
                waiter.next = self.top;
                self.top = waiter;
                self.len += 1;
            }

            fn pop(self: *WaitList) ?*Waiter {
                const waiter = self.top orelse return null;
                self.top = waiter.next;
                self.len -= 1;
                return waiter;
            }
        };

        const WaitQueue = struct {
            fn insert(treap: *Treap, address: usize, waiter: *Waiter) void {
                // prepare the waiter to be inserted.
                waiter.next = null;
                waiter.is_queued = true;

                // Find the wait queue entry associated with the address.
                // If there isn't a wait queue on the address, this waiter creates the queue.
                var entry = treap.getEntryFor(address);
                const entry_node = entry.node orelse {
                    waiter.prev = null;
                    waiter.tail = waiter;
                    entry.set(&waiter.node);
                    return;
                };

                // There's a wait queue on the address; get the queue head and tail.
                const head = @fieldParentPtr(Waiter, "node", entry_node);
                const tail = head.tail orelse unreachable;

                // Push the waiter to the tail by replacing it and linking to the previous tail.
                head.tail = waiter;
                tail.next = waiter;
                waiter.prev = tail;
            }

            fn remove(treap: *Treap, address: usize, max_waiters: usize) WaitList {
                // Find the wait queue associated with this address and get the
                // head/tail if any.
                var entry = treap.getEntryFor(address);
                var queue_head = if (entry.node) |node|
                    @fieldParentPtr(Waiter, "node", node)
                else
                    null;
                const queue_tail = if (queue_head) |head| head.tail else null;

                // Once we're done updating the head, fix it's tail pointer and update
                // the treap's queue head as well.
                defer entry.set(blk: {
                    const new_head = queue_head orelse break :blk null;
                    new_head.tail = queue_tail;
                    break :blk &new_head.node;
                });

                var removed = WaitList{};
                while (removed.len < max_waiters) {
                    // dequeue and collect waiters from their wait queue.
                    const waiter = queue_head orelse break;
                    queue_head = waiter.next;
                    removed.push(waiter);

                    // When dequeueing, we must mark is_queued as false.
                    // This ensures that a waiter which calls tryRemove() returns false.
                    assert(waiter.is_queued);
                    waiter.is_queued = false;
                }

                return removed;
            }

            fn tryRemove(treap: *Treap, address: usize, waiter: *Waiter) bool {
                if (!waiter.is_queued) {
                    return false;
                }

                queue_remove: {
                    // Find the wait queue associated with the address.
                    var entry = blk: {
                        // A waiter without a previous link means it's the queue head
                        // that's in the treap so we can avoid lookup.
                        if (waiter.prev == null) {
                            assert(waiter.node.key == address);
                            break :blk treap.getEntryForExisting(&waiter.node);
                        }
                        break :blk treap.getEntryFor(address);
                    };

                    // The queue head and tail must exist if we're removing a queued waiter.
                    const head = @fieldParentPtr(Waiter, "node", entry.node orelse unreachable);
                    const tail = head.tail orelse unreachable;

                    // A waiter with a previous link is never the head of the queue.
                    if (waiter.prev) |prev| {
                        assert(waiter != head);
                        prev.next = waiter.next;

                        // A waiter with both a previous and next link is in the middle.
                        // We only need to update the surrounding waiter's links to remove it.
                        if (waiter.next) |next| {
                            assert(waiter != tail);
                            next.prev = waiter.prev;
                            break :queue_remove;
                        }

                        // A waiter with a previous but no next link means it's the tail of the queue.
                        // In that case, we need to update the head's tail reference.
                        assert(waiter == tail);
                        head.tail = waiter.prev;
                        break :queue_remove;
                    }

                    // A waiter with no previous link means it's the queue head of queue.
                    // We must replace (or remove) the head waiter reference in the treap.
                    assert(waiter == head);
                    entry.set(blk: {
                        const new_head = waiter.next orelse break :blk null;
                        new_head.tail = head.tail;
                        break :blk &new_head.node;
                    });
                }

                // Mark the waiter as successfully removed.
                waiter.is_queued = false;
                return true;
            }
        };
    };
}
