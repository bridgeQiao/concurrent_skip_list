//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");
const mem = std.mem;
const skip_list = @import("concurrent_skip_list");

const NodeType = struct {
    const Self = @This();
    first: i32 = 0,
    second: i32 = 0,

    fn less(lhs: *const Self, rhs: *const Self) bool {
        return lhs.first < rhs.first;
    }
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const SkipListType = skip_list.ConcurrentSkipList(NodeType, &NodeType.less, 16);

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

    // do test
    const num_readers = 4;
    const num_writers = 4;
    for (0..2) |i| {
        _ = concurrent_test(gpa, init.io, @intCast(i), num_readers, num_writers);
    }
}

// 定义线程参数结构体
const ThreadArgs = struct {
    io: std.Io,
    mode: Mode,
    num: i32,
    id: i32,
    modulo: i32,
    duration_ms: i32,
    op_count: i32,
    temp: u64,
    sl: *SkipListType,
    stdmap: *std.hash_map.AutoHashMap(i32, i32),
    lock: *std.Thread.RwLock,

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
    var seed: u64 = undefined;
    args.io.random(std.mem.asBytes(&seed));
    var rng = std.Random.DefaultPrng.init(seed);
    while (timer.read() < @as(u64, @intCast(args.duration_ms)) * 1_000_000) {
        const r = rng.random().intRangeAtMost(i32, 0, args.num - 1);
        const max_walks: i32 = 3;
        var walks: i32 = 0;

        if (args.mode == .SKIPLIST) {
            var access = SkipListType.Accessor.init(args.sl);
            defer access.deinit();
            const data_r = NodeType{ .first = r };
            const find_data = access.find(&data_r);
            if (find_data != null) {
                args.temp += num_primes(@intCast(find_data.?.data().second), 10000);
                walks += 1;
            }
        } else if (args.mode == .MAP_MUTEX) {
            args.lock.lockShared();
            defer args.lock.unlockShared();
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
    var seed: u64 = undefined;
    args.io.random(std.mem.asBytes(&seed));
    var rng = std.Random.DefaultPrng.init(seed);
    while (timer.read() < @as(u64, @intCast(args.duration_ms)) * 1_000_000) {
        var r = rng.random().intRangeAtMost(i32, 0, @divTrunc(args.num, args.modulo) - 1);
        r *= args.modulo;
        r += args.id;

        if (args.mode == .SKIPLIST) {
            var access = SkipListType.Accessor.init(args.sl);
            defer access.deinit();
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
fn concurrent_test(allocator: mem.Allocator, io: std.Io, mode: i32, comptime num_readers: i32, comptime num_writers: i32) i32 {
    std.debug.print("concurrent test: {}\n", .{@as(ThreadArgs.Mode, @enumFromInt(mode))});

    // 初始化数据结构
    var sl = SkipListType.init(allocator);
    defer sl.deinit();
    var stdmap = std.hash_map.AutoHashMap(i32, i32).init(allocator);
    defer stdmap.deinit();
    var lock = std.Thread.RwLock{};

    const num: i32 = 10_000_000;
    const duration_ms: i32 = 5000;

    // 创建读者线程
    var r_args = [_]ThreadArgs{undefined} ** num_readers;
    var readers: std.ArrayList(std.Io.Future(void)) = .empty;
    defer readers.deinit(allocator);
    for (0..num_readers) |i| {
        r_args[i] = ThreadArgs{
            .io = io,
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
        readers.append(allocator, io.concurrent(reader, .{&r_args[i]}) catch unreachable) catch unreachable;
    }

    // 创建写者线程
    var w_args = [_]ThreadArgs{undefined} ** num_writers;
    // var writers = [_]std.Io.Future(void){} ** num_writers;
    var writers: std.ArrayList(std.Io.Future(void)) = .empty;
    defer writers.deinit(allocator);
    for (0..num_writers) |i| {
        w_args[i] = ThreadArgs{
            .io = io,
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
        writers.append(allocator, io.concurrent(writer, .{&w_args[i]}) catch unreachable) catch unreachable;
    }

    // 等待线程结束并统计操作数
    var r_total: i32 = 0;
    var w_total: i32 = 0;
    for (0..num_readers) |i| {
        readers.items[i].await(io);
        r_total += r_args[i].op_count;
    }
    for (0..num_writers) |i| {
        writers.items[i].await(io);
        w_total += w_args[i].op_count;
    }

    // 输出结果
    std.debug.print("read: {d:.1} ops/sec\n", .{@as(f64, @floatFromInt(r_total)) * 1000.0 / @as(f64, @floatFromInt(duration_ms))});
    std.debug.print("write: {d:.1} ops/sec\n", .{@as(f64, @floatFromInt(w_total)) * 1000.0 / @as(f64, @floatFromInt(duration_ms))});
    std.debug.print("total: {d:.1} ops/sec\n", .{@as(f64, @floatFromInt(r_total + w_total)) * 1000.0 / @as(f64, @floatFromInt(duration_ms))});

    return 0;
}
