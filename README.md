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

My computer is `Mac mini m2`, 8G memory. Use `-Doptimize=ReleaseSafe`, read is better, but write is less.

W1 R4:

```bash
concurrent test: main.ThreadArgs.Mode.SKIPLIST
read: 44504008.8 ops/sec
write: 357190.2 ops/sec
total: 44861199.0 ops/sec
concurrent test: main.ThreadArgs.Mode.MAP_MUTEX
read: 1622013.6 ops/sec
write: 3140.0 ops/sec
total: 1625153.6 ops/sec
```

W1 R8:

```bash
concurrent test: main.ThreadArgs.Mode.SKIPLIST
read: 42400553.4 ops/sec
write: 449721.0 ops/sec
total: 42850274.4 ops/sec
concurrent test: main.ThreadArgs.Mode.MAP_MUTEX
read: 6344752.2 ops/sec
write: 7511.6 ops/sec
total: 6352263.8 ops/sec
```

W4 R4:

```bash
concurrent test: main.ThreadArgs.Mode.SKIPLIST
read: 28497686.4 ops/sec
write: 1700419.0 ops/sec
total: 30198105.4 ops/sec
concurrent test: main.ThreadArgs.Mode.MAP_MUTEX
read: 2238460.2 ops/sec
write: 316186.6 ops/sec
total: 2554646.8 ops/sec
```
