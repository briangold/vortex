const std = @import("std");
const assert = std.debug.assert;

pub fn FwdIndexedList(
    comptime T: anytype, // type we're linking together
    comptime link_field: std.meta.FieldEnum(T),
) type {
    return struct {
        const Self = @This();

        const link_info = std.meta.fieldInfo(T, link_field);
        const link_name = link_info.name;
        pub const Index = switch (@typeInfo(link_info.field_type)) {
            .Optional => |info| info.child,
            else => @compileError("expected optional type in link"),
        };

        array: []T,
        head: ?Index = null,
        tail: ?Index = null,

        pub fn init(array: []T) Self {
            return Self{ .array = array };
        }

        pub fn push(self: *Self, idx: Index) void {
            if (self.tail) |tail| {
                var tail_entry = &self.array[tail];
                @field(tail_entry, link_name) = idx;
                self.tail = idx;
            } else {
                assert(self.head == null);
                self.head = idx;
                self.tail = idx;
            }
        }

        pub fn pop(self: *Self) ?Index {
            const head = self.head orelse return null;

            var head_entry = &self.array[head];
            self.head = @field(head_entry, link_name);
            if (self.tail == head) {
                assert(self.head == null);
                self.tail = null;
            }

            @field(head_entry, link_name) = null;
            return head;
        }

        pub fn peek(self: *const Self) ?Index {
            return self.head;
        }

        pub fn iter(self: *const Self) Iterator(Self) {
            return Iterator(Self){
                .list = self,
                .cur = self.head,
            };
        }

        pub fn unlink(self: *Self, idx: Index) bool {
            var it = self.iter();
            while (it.get()) |elem_idx| : (_ = it.next()) {
                if (idx == elem_idx) {
                    _ = self.delete(&it) orelse unreachable;
                    return true;
                }
            }
            return false;
        }

        // TODO: comment - NOTE that delete advances the iterator
        // so beware of using this in a while loop
        pub fn delete(self: *Self, it: *Iterator(Self)) ?Index {
            const cur = it.cur orelse return null;
            var cur_entry = &self.array[cur];
            const next = @field(cur_entry, link_name);
            @field(cur_entry, link_name) = null;

            if (it.prev) |prev| {
                @field(self.array[prev], link_name) = next;
            } else {
                self.head = next;
            }

            if (next == null) self.tail = it.prev;

            it.cur = next;

            return cur;
        }
    };
}

fn Iterator(comptime List: anytype) type {
    return struct {
        const Self = @This();

        list: *const List,

        prev: ?List.Index = null,
        cur: ?List.Index,

        pub fn get(self: *Self) ?List.Index {
            return self.cur;
        }

        pub fn next(self: *Self) ?List.Index {
            const cur_idx = self.cur orelse return null;
            const cur_entry = self.list.array[cur_idx];
            self.prev = self.cur;

            const fwd = @field(cur_entry, List.link_name);
            self.cur = fwd;
            return self.cur;
        }
    };
}

test "basic" {
    const Test = struct {
        x: u32,
        next: ?usize = null,
    };

    const TestList = FwdIndexedList(Test, .next);
    try std.testing.expect(TestList.Index == usize);

    var arr = [2]Test{
        .{ .x = 1 },
        .{ .x = 2 },
    };
    var l = TestList.init(&arr);

    l.push(0);
    try std.testing.expectEqual(@as(u32, 1), arr[l.peek().?].x);

    l.push(1);
    try std.testing.expectEqual(@as(u32, 1), arr[l.peek().?].x);

    try std.testing.expectEqual(@as(u32, 1), arr[l.pop().?].x);
    try std.testing.expectEqual(@as(u32, 2), arr[l.peek().?].x);
    try std.testing.expectEqual(@as(u32, 2), arr[l.pop().?].x);
    try std.testing.expect(l.pop() == null);

    l.push(0);
    l.push(1);

    {
        var it = l.iter();
        var count: usize = 0;
        while (it.get()) |elem| : (_ = it.next()) {
            try std.testing.expect(elem == count);
            count += 1;
        }
        try std.testing.expect(it.get() == null);
    }

    {
        var it = l.iter();
        try std.testing.expect(l.delete(&it).? == 0);
        try std.testing.expect(it.get().? == 1);
        try std.testing.expect(l.delete(&it).? == 1);
        try std.testing.expect(it.get() == null);
        try std.testing.expect(l.head == null);
        try std.testing.expect(l.tail == null);
        try std.testing.expect(l.delete(&it) == null);
    }

    l.push(0);
    l.push(1);

    {
        var it = l.iter();
        try std.testing.expect(it.get().? == 0);
        try std.testing.expect(it.next().? == 1);
        try std.testing.expect(l.delete(&it).? == 1);
        try std.testing.expect(it.get() == null);
        try std.testing.expect(l.head.? == l.tail.?);
    }
}
