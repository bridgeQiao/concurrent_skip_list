# concurrent_skip_list

Folly-inspired, Zig-powered.

This project provides a high-performance **concurrent skip list** (lock-free / fine-grained locking variants are available) designed for multi-threaded key-value workloads. BenchMark origin: [greensky00/skiplist](https://github.com/greensky00/skiplist.git). Thanks!

## Performance Recommendations

This implementation compared different concurrency strategies. Choose the most suitable one based on your workload and hardware:

- **Skiplist (preferred choice)**

  We generally recommend using the **skiplist-based** concurrent map in any scenario. However, you **must benchmark it first** in your actual deployment environment to ensure it performs as expected. Be aware that performance can be significantly affected by Docker containers, third-party memory allocators (e.g., mimalloc), and other environmental factors.

- **Mutex + hash_map** (fallback if skiplist doesn't perform as expected)

  For **general-purpose** use cases or machines with moderate core counts (< work threads num), the **mutex + hash_map** implementation often delivers the most balanced performance — good throughput for both reads and writes.

- **RWLock + hash_map** (read-heavy workloads)

  If your workload is **heavily read-dominant**, the **reader-writer lock + hash_map** variant can provide significantly better performance under concurrent reads.
  However, write performance will be noticeably worse than the mutex-based version — only choose this when reads clearly dominate.

Quick summary:

| Scenario                          | Recommended Choice       | When to prefer it                              |
|-----------------------------------|---------------------------|------------------------------------------------|
| Any scenario                      | Skiplist                 | Always preferred, but must benchmark first    |
| General / balanced workload       | Mutex + hash_map         | Most consistent & predictable performance      |
| Read-heavy (many more reads)      | RWLock + hash_map        | Maximize read throughput, accept slower writes |

Feel free to run your own benchmarks with your specific workload, key distribution, and hardware — the best choice can vary depending on actual access patterns.

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
