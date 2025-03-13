//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");
const skip_list = @import("concurrent_skip_list.zig");

const NodeType = struct {
    const Self = @This();
    first: i32 = 0,
    second: i32 = 0,

    fn less(lhs: *const Self, rhs: *const Self) bool {
        return lhs.first < rhs.first;
    }
};
const SkipListType = skip_list.ConcurrentSkipList(NodeType, &NodeType.less, std.heap.page_allocator, 16);

pub fn main() !void {
    const data: NodeType = .{ .first = 30, .second = 30 };
    var sl = SkipListType.init();
    defer sl.deinit();

    var access = skip_list.Accessor(SkipListType).init(&sl);
    defer access.deinit();
    _ = access.add(&data);
    if (access.contains(&data)) {
        std.debug.print("data: {}\n", .{access.find(&data).?.data().*});
    }
    std.debug.print("{*}\n", .{access.first()});

    // do test
    const num_threads = 8;
    for (0..2) |i| {
        _ = concurrent_test(@intCast(i), num_threads, num_threads);
    }
}

// 定义线程参数结构体
const ThreadArgs = struct {
    mode: Mode,
    num: i32,
    id: i32,
    modulo: i32,
    duration_ms: i32,
    op_count: i32,
    temp: u64,
    sl: *SkipListType,
    stdmap: *std.hash_map.AutoHashMap(i32, i32),
    lock: *std.Thread.Mutex,

    // 模式枚举
    const Mode = enum {
        SKIPLIST,
        MAP_MUTEX,
        MAP_ONLY,
    };
};

// 计算质因数的个数
fn num_primes(number: u64, max_prime: usize) usize {
    var ret: usize = 0;
    var ii: usize = 2;
    while (ii <= max_prime) : (ii += 1) {
        var num = number;
        if (num % ii == 0) {
            num /= ii;
            ret += 1;
        }
    }
    return ret;
}

// 读者线程函数
fn reader(args: *ThreadArgs) void {
    var timer = std.time.Timer.start() catch unreachable;
    while (timer.read() < @as(u64, @intCast(args.duration_ms)) * 1_000_000) {
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const r = rng.random().intRangeAtMost(i32, 0, args.num - 1);
        const max_walks: i32 = 3;
        var walks: i32 = 0;

        if (args.mode == .SKIPLIST) {
            var access = skip_list.Accessor(SkipListType).init(args.sl);
            const data_r = NodeType{ .first = r };
            const find_data = access.find(&data_r);
            if (find_data != null) {
                args.temp += num_primes(@intCast(find_data.?.data().second), 10000);
                walks += 1;
            }
        } else if (args.mode == .MAP_MUTEX) {
            args.lock.lock();
            defer args.lock.unlock();
            if (args.stdmap.get(r)) |value| {
                args.temp += num_primes(@intCast(value), 10000);
                walks += 1;
            }
        } else { // MAP_ONLY
            if (args.stdmap.get(r)) |value| {
                args.temp += num_primes(@intCast(value), 10000);
                walks += 1;
            }
        }
        args.op_count += max_walks;
    }
}

// 写者线程函数
fn writer(args: *ThreadArgs) void {
    var timer = std.time.Timer.start() catch unreachable;
    while (timer.read() < @as(u64, @intCast(args.duration_ms)) * 1_000_000) {
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        var r = rng.random().intRangeAtMost(i32, 0, @divTrunc(args.num, args.modulo) - 1);
        r *= args.modulo;
        r += args.id;

        if (args.mode == .SKIPLIST) {
            var access = skip_list.Accessor(SkipListType).init(args.sl);
            const data_r = NodeType{ .first = r };
            if (access.contains(&data_r)) {
                _ = access.remove(&data_r);
            } else {
                const data_add = NodeType{ .first = r, .second = r };
                _ = access.add(&data_add);
            }
        } else if (args.mode == .MAP_MUTEX) {
            args.lock.lock();
            defer args.lock.unlock();
            if (args.stdmap.contains(r)) {
                _ = args.stdmap.remove(r);
            } else {
                args.stdmap.put(r, r) catch unreachable;
            }
        } else { // MAP_ONLY
            if (args.stdmap.contains(r)) {
                _ = args.stdmap.remove(r);
            } else {
                args.stdmap.put(r, r) catch unreachable;
            }
        }
        args.op_count += 1;
    }
}

// 并发测试函数
fn concurrent_test(mode: i32, comptime num_readers: i32, comptime num_writers: i32) i32 {
    std.debug.print("concurrent test: {}\n", .{@as(ThreadArgs.Mode, @enumFromInt(mode))});
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 初始化数据结构
    var sl = SkipListType.init();
    var stdmap = std.hash_map.AutoHashMap(i32, i32).init(allocator);
    var lock = std.Thread.Mutex{};

    const num: i32 = 10_000_000;
    const duration_ms: i32 = 5000;

    // 创建读者线程
    var r_args = [_]ThreadArgs{undefined} ** num_readers;
    var readers = [_]std.Thread{undefined} ** num_readers;
    for (0..num_readers) |i| {
        r_args[i] = ThreadArgs{
            .mode = @enumFromInt(mode),
            .num = num,
            .id = 0,
            .modulo = 0,
            .duration_ms = duration_ms,
            .op_count = 0,
            .temp = 0,
            .sl = &sl,
            .stdmap = &stdmap,
            .lock = &lock,
        };
        readers[i] = std.Thread.spawn(.{}, reader, .{&r_args[i]}) catch unreachable;
    }

    // 创建写者线程
    var w_args = [_]ThreadArgs{undefined} ** num_writers;
    var writers = [_]std.Thread{undefined} ** num_writers;
    for (0..num_writers) |i| {
        w_args[i] = ThreadArgs{
            .mode = @enumFromInt(mode),
            .num = num,
            .id = @intCast(i),
            .modulo = num_writers,
            .duration_ms = duration_ms,
            .op_count = 0,
            .temp = 0,
            .sl = &sl,
            .stdmap = &stdmap,
            .lock = &lock,
        };
        writers[i] = std.Thread.spawn(.{}, writer, .{&w_args[i]}) catch unreachable;
    }

    // 等待线程结束并统计操作数
    var r_total: i32 = 0;
    var w_total: i32 = 0;
    for (0..num_readers) |i| {
        readers[i].join();
        r_total += r_args[i].op_count;
    }
    for (0..num_writers) |i| {
        writers[i].join();
        w_total += w_args[i].op_count;
    }

    // 输出结果
    std.debug.print("read: {d:.1} ops/sec\n", .{@as(f64, @floatFromInt(r_total)) * 1000.0 / @as(f64, @floatFromInt(duration_ms))});
    std.debug.print("write: {d:.1} ops/sec\n", .{@as(f64, @floatFromInt(w_total)) * 1000.0 / @as(f64, @floatFromInt(duration_ms))});
    std.debug.print("total: {d:.1} ops/sec\n", .{@as(f64, @floatFromInt(r_total + w_total)) * 1000.0 / @as(f64, @floatFromInt(duration_ms))});

    return 0;
}
