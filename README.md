# concurrent_skip_list

Folly-inspired, Zig-powered.

This project provides a high-performance **concurrent skip list** (lock-free / fine-grained locking variants are available) designed for multi-threaded key-value workloads. BenchMark origin: [greensky00/skiplist](https://github.com/greensky00/skiplist.git). Thanks!

## Performance Recommendations

This implementation compared different concurrency strategies. Choose the most suitable one based on your workload and hardware:

- **Skiplist** (prioritize write performance)

  The **skiplist-based** concurrent map is optimized to prioritize write performance. However, you **must benchmark it first** in your actual deployment environment to ensure it performs as expected. Be aware that performance can be significantly affected by Docker containers, third-party memory allocators (e.g., mimalloc), and other environmental factors.

- **Mutex + hash_map** (fallback if skiplist doesn't perform as expected)

  For **general-purpose** use cases, the **mutex + hash_map** implementation often delivers the most balanced performance — good throughput for both reads and writes.

- **RWLock + hash_map** (prioritize read performance)

  The **reader-writer lock + hash_map** variant is optimized to prioritize read performance and can provide significantly better throughput under concurrent reads.
  However, write performance will be noticeably worse than the mutex-based version — only choose this when reads clearly dominate.

Quick summary:

| Scenario                          | Recommended Choice       | When to prefer it                              |
|-----------------------------------|---------------------------|------------------------------------------------|
| Prioritize write performance      | Skiplist                 | Optimized for write throughput, must benchmark first |
| General / balanced workload       | Mutex + hash_map         | Most consistent & predictable performance      |
| Prioritize read performance       | RWLock + hash_map        | Optimized for read throughput, accept slower writes |

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

W8 R1:

```bash
concurrent test: .SKIPLIST
read: 651899.4 ops/sec
write: 2228922.6 ops/sec
total: 2880822.0 ops/sec
concurrent test: .MAP_MUTEX
read: 5443653.0 ops/sec
write: 169249.2 ops/sec
total: 5612902.2 ops/sec
```

W1 R8:

```bash
concurrent test: .SKIPLIST
read: 9461286.0 ops/sec
write: 431863.2 ops/sec
total: 9893149.2 ops/sec
concurrent test: .MAP_MUTEX
read: 13446618.6 ops/sec
write: 57112.0 ops/sec
total: 13503730.6 ops/sec
```

W4 R4:

```bash
concurrent test: .SKIPLIST
read: 3441819.6 ops/sec
write: 1377360.8 ops/sec
total: 4819180.4 ops/sec
concurrent test: .MAP_MUTEX
read: 7980547.2 ops/sec
write: 111181.2 ops/sec
total: 8091728.4 ops/sec
```
