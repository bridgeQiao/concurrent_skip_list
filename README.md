# concurrent_skip_list

Copy from folly project:) Rewrite the code to zig.
BenchMark origin: [greensky00/skiplist](https://github.com/greensky00/skiplist.git). Thanks!

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
    defer access.deinit();
    _ = access.add(&data);
    if (access.contains(&data)) {
        std.debug.print("data: {}\n", .{access.find(&data).?.data().*});
    }
    std.debug.print("{*}\n", .{access.first()});
}
```

## BenchMark

My computer is `Mac mini m2`, 8G memory. Read is better, but write is less. Maybe it's wrong code :(

num thread 4:

```bash
concurrent test: main.ThreadArgs.Mode.SKIPLIST
read: 31427253.0 ops/sec
write: 1992170.4 ops/sec
total: 33419423.4 ops/sec
concurrent test: main.ThreadArgs.Mode.MAP_MUTEX
read: 2273837.4 ops/sec
write: 310903.8 ops/sec
total: 2584741.2 ops/sec
```

num thread 8:

```bash
concurrent test: main.ThreadArgs.Mode.SKIPLIST
read: 29111447.4 ops/sec
write: 770173.6 ops/sec
total: 29881621.0 ops/sec
concurrent test: main.ThreadArgs.Mode.MAP_MUTEX
read: 5845453.2 ops/sec
write: 1110479.6 ops/sec
total: 6955932.8 ops/sec
```
