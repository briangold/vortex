//! A CancelQueue is a singly linked list that supports two operations:
//! `insert` a new item and `unlink` the entire list. Both are thread-safe,
//! with `unlink` enabling a caller to traverse the list without holding a
//! lock.
//!
//! This data structure is designed to model the cancellation of I/O operations
//! in multiple platform backends, where cancellation may be requested from
//! any thread, but must be processed by a specific thread where the I/O
//! originated.

const std = @import("std");

/// A `CancelQueue` is an intrusive structure over `Node` types, where
/// `link_name` is the "next" pointer in Node.
pub fn CancelQueue(comptime Node: type, comptime link_name: []const u8) type {
    if (!@hasField(Node, link_name))
        @compileError(@typeName(Node) ++ " does not contain link `" ++ link_name ++ "`");

    return struct {
        const Queue = @This();

        mutex: std.Thread.Mutex = .{},
        head: ?*Node = null,
        tail: ?*Node = null,

        /// Inserts a new `node` onto CancelQueue `q`.
        pub fn insert(q: *Queue, node: *Node) void {
            q.mutex.lock();
            defer q.mutex.unlock();

            if (q.head == null) q.head = node;
            if (q.tail) |tail| {
                @field(tail, link_name) = node;
            }
            q.tail = node;
        }

        /// Unlinks entire chain, returning an iterator
        pub fn unlink(q: *Queue) Iterator {
            // TODO: measure impact of this optimization
            if (@atomicLoad(?*Node, &q.head, .Monotonic) == null) {
                return Iterator{ .cur = null };
            }

            q.mutex.lock();
            defer q.mutex.unlock();

            const head = q.head;
            q.head = null;
            q.tail = null;

            return Iterator{
                .cur = head,
            };
        }

        const Iterator = struct {
            prev: ?*Node = null,
            cur: ?*Node,

            pub fn get(it: *Iterator) ?*Node {
                return it.cur;
            }

            pub fn next(it: *Iterator) ?*Node {
                it.prev = it.cur orelse return null;
                it.cur = @field(it.prev.?, link_name);
                return it.cur;
            }
        };
    };
}
