//! A CancelQueue is a singly linked list that supports two operations:
//! `insert` a new item and `unlink` the entire list. Both are thread-safe,
//! with `unlink` enabling a caller to traverse the list without holding a
//! lock. Nodes in the list are intrusive and ownership over the node is
//! retained by the caller. Thus, the lifetime of a node must outlive its
//! life on the list.
//!
//! This data structure is designed to model the cancellation of I/O operations
//! in multiple platform backends, where cancellation may be requested from
//! any thread, but must be processed by a specific thread where the I/O
//! originated. The lifetime of a "Node" (IoOperation) must outlive the
//! cancellation duration.

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

test "CancelQueue" {
    const alloc = std.testing.allocator;

    const TestNode = struct {
        canceled: bool = false,
        next: ?*@This() = null,
    };

    const Queue = CancelQueue(TestNode, "next");

    const Worker = struct {
        fn entry(queue: *Queue, num_iter: usize) void {
            // items to enqueue must outlive cancellation
            var items = alloc.alloc(TestNode, num_iter) catch unreachable;
            defer alloc.free(items);

            for (items) |*it| {
                it.* = TestNode{};
                queue.insert(it);
            }

            // spin while waiting for cancelation to finish
            for (items) |*it| {
                while (@atomicLoad(bool, &it.canceled, .Monotonic) == false) {}
            }
        }
    };

    const num_threads = 4;
    const num_iter = 1000;

    var workers = try alloc.alloc(std.Thread, num_threads);
    defer alloc.free(workers);

    var queue = Queue{};

    for (workers) |*w| {
        w.* = try std.Thread.spawn(
            .{},
            Worker.entry,
            .{ &queue, num_iter },
        );
    }

    var count: usize = 0;
    while (count < num_iter * num_threads) {
        var to_cancel = queue.unlink();
        while (to_cancel.get()) |item| : (_ = to_cancel.next()) {
            @atomicStore(bool, &item.canceled, true, .Monotonic);
            count += 1;
        }
    }

    for (workers) |*w| {
        w.join();
    }
}
