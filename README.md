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

My computer is `Mac mini m2`, 8G memory. Use `-Doptimize=ReleaseSafe`.

W1 R4:

```bash
concurrent test: main.ThreadArgs.Mode.SKIPLIST
read: 59116408.8 ops/sec
write: 516296.6 ops/sec
total: 59632705.4 ops/sec
concurrent test: main.ThreadArgs.Mode.MAP_MUTEX
read: 1550502.0 ops/sec
write: 2444.8 ops/sec
total: 1552946.8 ops/sec
```

W1 R8:

```bash
concurrent test: main.ThreadArgs.Mode.SKIPLIST
read: 52487349.6 ops/sec
write: 553217.8 ops/sec
total: 53040567.4 ops/sec
concurrent test: main.ThreadArgs.Mode.MAP_MUTEX
read: 6319045.2 ops/sec
write: 8136.4 ops/sec
total: 6327181.6 ops/sec
```

W4 R4:

```bash
concurrent test: main.ThreadArgs.Mode.SKIPLIST
read: 47985684.6 ops/sec
write: 2717000.4 ops/sec
total: 50702685.0 ops/sec
concurrent test: main.ThreadArgs.Mode.MAP_MUTEX
read: 2650765.8 ops/sec
write: 462557.8 ops/sec
total: 3113323.6 ops/sec
```
