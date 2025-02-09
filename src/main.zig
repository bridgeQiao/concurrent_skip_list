//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");
const skip_list = @import("concurrent_skip_list.zig");

const NodeType = struct {
    const Self = @This();
    first: i32 = 0,
    second: i32 = 0,

    fn less(lhs: Self, rhs: Self) bool {
        return lhs.first < rhs.first;
    }
};

pub fn main() !void {
    const SkipListType = skip_list.ConcurrentSkipList(NodeType, &NodeType.less, std.heap.page_allocator, 16);
    const data: NodeType = .{ .first = 30, .second = 30 };
    var sl = SkipListType.init();
    defer sl.deinit();

    var access = skip_list.Accessor(SkipListType).init(&sl);
    _ = access.add(&data);
    std.debug.print("{*}", .{access.first()});
    access.deinit();
}
