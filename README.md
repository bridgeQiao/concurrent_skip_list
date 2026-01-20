# concurrent_skip_list

Folly-inspired, Zig-powered.

BenchMark origin: [greensky00/skiplist](https://github.com/greensky00/skiplist.git). Thanks!

## use it

### 1. add the repo

execute:

```bash
zig fetch --save git+https://github.com/bridgeQiao/concurrent_skip_list.git
```

In `build.zig` add import:

```zig
const con_skiplist_dep = b.dependency("concurrent_skip_list", .{
    .target = target,
    .optimize = optimize,
});
const con_skiplist = con_skiplist_dep.module("concurrent_skip_list");

// ...
exe.root_module.addImport("concurrent_skip_list", con_skiplist);
```

### 2. import

```zig
const skip_list = @import("concurrent_skip_list");

// define data type
const NodeType = struct {
    const Self = @This();
    first: i32 = 0,
    second: i32 = 0,

    fn less(lhs: *const Self, rhs: *const Self) bool {
        return lhs.first < rhs.first;
    }
};
const SkipListType = skip_list.ConcurrentSkipList(NodeType, &NodeType.less, 16);

// main
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const data: NodeType = .{ .first = 30, .second = 30 };
    var sl = SkipListType.init(gpa);
    defer sl.deinit();

    var access = SkipListType.Accessor.init(&sl);
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
concurrent test: .SKIPLIST
read: 6132613.8 ops/sec
write: 561943.2 ops/sec
total: 6694557.0 ops/sec
concurrent test: .MAP_MUTEX
read: 1047670.2 ops/sec
write: 86658.6 ops/sec
total: 1134328.8 ops/sec
```

W1 R8:

```bash
concurrent test: .SKIPLIST
read: 9415477.8 ops/sec
write: 423367.6 ops/sec
total: 9838845.4 ops/sec
concurrent test: .MAP_MUTEX
read: 1333158.0 ops/sec
write: 54452.8 ops/sec
total: 1387610.8 ops/sec
```

W4 R4:

```bash
concurrent test: .SKIPLIST
read: 3216448.8 ops/sec
write: 1333397.8 ops/sec
total: 4549846.6 ops/sec
concurrent test: .MAP_MUTEX
read: 731891.4 ops/sec
write: 243959.6 ops/sec
total: 975851.0 ops/sec
```
