const std = @import("std");
const atomic = std.atomic;
const Thread = std.Thread;

pub fn SkipListNode(ValueType: type, allocator: std.mem.Allocator) type {
    const Flag = struct {
        pub const Init: u16 = 0;
        pub const IsHeadNode: u16 = 1 << 0; // 二进制 0000_0001 (1)
        pub const MarkedForRemoval: u16 = 1 << 1; // 二进制 0000_0010 (2)
        pub const FullyLinked: u16 = 1 << 2; // 二进制 0000_0100 (4)
    };
    return struct {
        const Self = @This();

        flags_: atomic.Value(u16),
        height_: u8,
        spinLock_: Thread.Mutex,
        data_: ValueType,
        skip_: std.ArrayList(atomic.Value(?*Self)),

        pub fn create(node_height: usize, value_data: *const ValueType, option: ?struct { isHead: bool = false }) *Self {
            var flag: atomic.Value(u16) = undefined;
            flag.store(Flag.Init, .release);
            if (option) |opt| {
                if (opt.isHead) {
                    flag.store(Flag.IsHeadNode, .release);
                }
            }

            var ret = allocator.create(Self) catch unreachable;

            ret.* = Self{
                .flags_ = flag,
                .height_ = @intCast(node_height),
                .spinLock_ = Thread.Mutex{},
                .data_ = value_data.*,
                .skip_ = std.ArrayList(atomic.Value(?*Self)).init(allocator),
            };
            ret.skip_.appendNTimes(atomic.Value(?*Self){ .raw = null }, node_height) catch unreachable;
            return ret;
        }

        pub fn destroy(self: *Self) void {
            self.skip_.deinit();
            allocator.destroy(self);
        }

        pub fn copyHead(self: *Self, node: *Self) *Self {
            self.setFlags(node.getFlags());
            for (0..node.height_) |i| {
                self.setSkip(@intCast(i), node.skip(i));
            }
            return self;
        }

        pub inline fn skip(self: *Self, layer: usize) ?*Self {
            return self.skip_.items[layer].load(.acquire);
        }

        // next valid node as in the linked list
        pub fn next(self: *Self) *Self {
            var node: *Self = self.skip(0);
            while (node != null and node.markedForRemoval()) : (node = node.skip(0)) {}
            return node;
        }

        pub fn setSkip(self: *Self, h: u8, skip_node: ?*Self) void {
            self.skip_.items[h].store(skip_node, .release);
        }

        pub fn data(self: *const Self) *ValueType {
            return @constCast(&self.data_);
        }
        pub fn maxLayer(self: *Self) i32 {
            return self.height_ - 1;
        }
        pub fn height(self: *Self) usize {
            return self.height_;
        }

        pub fn acquireGuard(self: *Self) *Thread.Mutex {
            return &self.spinLock_;
        }

        pub fn fullyLinked(self: *Self) bool {
            return self.getFlags() & Flag.FullyLinked != 0;
        }
        pub fn markedForRemoval(self: *Self) bool {
            return self.getFlags() & Flag.MarkedForRemoval != 0;
        }
        pub fn isHeadNode(self: *Self) bool {
            return self.getFlags() & Flag.IsHeadNode;
        }

        pub fn setIsHeadNode(self: *Self) void {
            self.setFlags(getFlags() | Flag.IsHeadNode);
        }
        pub fn setFullyLinked(self: *Self) void {
            self.setFlags(self.getFlags() | Flag.FullyLinked);
        }
        pub fn setMarkedForRemoval(self: *Self) void {
            self.setFlags(self.getFlags() | Flag.MarkedForRemoval);
        }
        fn getFlags(self: *Self) u16 {
            return self.flags_.load(.acquire);
        }
        fn setFlags(self: *Self, flags: u16) void {
            self.flags_.store(flags, .release);
        }
    };
}

pub const SkipListRandomHeight = struct {
    const Self = @This();
    const kMaxHeight = 64;

    lookupTable_: [kMaxHeight]f64,
    sizeLimitTable_: [kMaxHeight]isize,

    pub fn instance() *Self {
        const Instance = struct {
            var b_init = atomic.Value(bool){ .raw = false };
            var lock: Thread.Mutex = Thread.Mutex{};
            var random_height: Self = Self{ .lookupTable_ = undefined, .sizeLimitTable_ = undefined };
        };
        if (!Instance.b_init.load(.acquire)) {
            Instance.lock.lock();
            defer Instance.lock.unlock();
            if (!Instance.b_init.load(.acquire)) {
                Instance.random_height.initLookupTable();
                Instance.b_init.store(true, .release);
            }
        }
        return &Instance.random_height;
    }

    pub fn getHeight(self: *Self, maxHeight: usize) usize {
        std.debug.assert(maxHeight <= kMaxHeight);
        const p = randomProb();
        for (0..@intCast(maxHeight)) |i| {
            if (p < self.lookupTable_[i]) {
                return @intCast(i + 1);
            }
        }
        return maxHeight;
    }

    pub fn getSizeLimit(self: *Self, height: usize) isize {
        std.debug.assert(height < kMaxHeight);
        return self.sizeLimitTable_[height];
    }

    fn initLookupTable(self: *Self) void {
        // set skip prob = 1/E
        const kProbInv: f64 = std.math.exp(1.0);
        const kProb: f64 = 1.0 / kProbInv;
        const kMaxSizeLimit: isize = std.math.maxInt(isize);

        var sizeLimit: f64 = 1;
        var p = (1 - kProb);
        self.lookupTable_[0] = p;
        self.sizeLimitTable_[0] = 1;

        var i: usize = 1;
        while (i < kMaxHeight - 1) : (i += 1) {
            p *= kProb;
            sizeLimit *= kProbInv;
            self.lookupTable_[i] = self.lookupTable_[i - 1] + p;
            self.sizeLimitTable_[i] = if (sizeLimit > std.math.maxInt(isize)) std.math.maxInt(isize) else @intFromFloat(sizeLimit);
        }
        self.lookupTable_[kMaxHeight - 1] = 1;
        self.sizeLimitTable_[kMaxHeight - 1] = kMaxSizeLimit;
    }

    fn randomProb() f64 {
        const rng = struct {
            var b_init = atomic.Value(bool){ .raw = false };
            var lock: Thread.Mutex = Thread.Mutex{};
            var prng: std.Random.Xoshiro256 = undefined;
            var rand: std.Random = undefined;
        };
        if (rng.b_init.load(.acquire) == false) {
            rng.lock.lock();
            defer rng.lock.unlock();
            if (rng.b_init.load(.acquire) == false) {
                rng.prng = std.Random.DefaultPrng.init(blk: {
                    var seed: u64 = undefined;
                    std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
                    break :blk seed;
                });
                rng.rand = rng.prng.random();
                rng.b_init.store(true, .release);
            }
        }
        return rng.rand.float(f64);
    }
};

pub fn NodeRecycler(NodeType: type, NodeAlloc: std.mem.Allocator) type {
    return struct {
        const Self = @This();
        nodes: *std.ArrayList(*NodeType),
        refs_: atomic.Value(i32) = atomic.Value(i32){ .raw = 0 }, // current number of visitors to the list
        dirty: atomic.Value(bool) = atomic.Value(bool){ .raw = false }, // whether *nodes_ is non-empty
        lock: Thread.Mutex = Thread.Mutex{}, // protects access to *nodes_

        pub fn init() Self {
            const ret = Self{
                .nodes = NodeAlloc.create(std.ArrayList(*NodeType)) catch unreachable,
            };
            ret.nodes.* = std.ArrayList(*NodeType).init(NodeAlloc);
            return ret;
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit();
            NodeAlloc.destroy(self.nodes);
        }

        pub fn add(self: *Self, node: *NodeType) void {
            self.lock.lock();
            defer self.lock.unlock();

            self.nodes.append(node) catch unreachable;
            self.dirty.store(true, .release);
        }

        pub fn addRef(self: *Self) i32 {
            return self.refs_.fetchAdd(1, .acq_rel);
        }

        pub fn releaseRef(self: *Self) i32 {
            // This if statement is purely an optimization. It's possible that this
            // misses an opportunity to delete, but that's OK, we'll try again at
            // the next opportunity. It does not harm the thread safety. For this
            // reason, we can use relaxed loads to make the decision.
            if (!self.dirty.load(.acquire) or self.refs() > 1) {
                return self.refs_.fetchAdd(-1, .acq_rel);
            }

            var newNodes: ?*std.ArrayList(*NodeType) = null;
            var ret: i32 = 0;
            {
                // The order at which we lock, add, swap, is very important for
                // correctness.
                self.lock.lock();
                defer self.lock.unlock();

                ret = self.refs_.fetchAdd(-1, .acq_rel);
                if (ret == 1) {
                    // When releasing the last reference, it is safe to remove all the
                    // current nodes in the recycler, as we already acquired the lock here
                    // so no more new nodes can be added, even though new accessors may be
                    // added after this.
                    newNodes = NodeAlloc.create(std.ArrayList(*NodeType)) catch unreachable;
                    newNodes.?.* = std.ArrayList(*NodeType).init(NodeAlloc);
                    const temp = self.nodes;
                    self.nodes = newNodes.?;
                    newNodes = temp;
                    self.dirty.store(false, .release);
                }
            }
            // TODO(xliu) should we spawn a thread to do this when there are large
            // number of nodes in the recycler?
            if (newNodes != null) {
                for (newNodes.?.items) |node| {
                    node.destroy();
                }
            }
            return ret;
        }

        fn refs(self: *Self) i32 {
            return self.refs_.load(.acquire);
        }
    };
}

test "skip list node" {
    const NodeType = SkipListNode(i32, std.testing.allocator);
    const data: i32 = 64;
    const node = NodeType.create(32, &data, null);
    defer node.destroy();
    std.debug.print("{}", .{node.data_});
}
