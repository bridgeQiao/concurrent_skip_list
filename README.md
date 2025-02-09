# concurrent_skip_list

Copy from folly project:) Rewrite the code to zig.

## use it

### 1. copy file

copy `src/concurrent_skip_list.zig` and `src/concurrent_skip_list_inc.zig` to your project.

### 2. import

```zig
const skip_list = @import("concurrent_skip_list.zig");

// define data type
const NodeType = struct {
    const Self = @This();
    first: i32 = 0,
    second: i32 = 0,

    fn less(lhs: *const Self, rhs: *const Self) bool {
        return lhs.first < rhs.first;
    }
};

// main
pub fn main() !void {
    const SkipListType = skip_list.ConcurrentSkipList(NodeType, &NodeType.less, std.heap.page_allocator, 16);
    const data: NodeType = .{ .first = 30, .second = 30 };
    var sl = SkipListType.init();
    defer sl.deinit();

    // for multithread safety, use Accessor to add or remove
    var access = skip_list.Accessor(SkipListType).init(&sl);
    _ = access.add(&data);
    std.debug.print("{*}", .{access.first()});
    access.deinit();
}
```