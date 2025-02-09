const std = @import("std");
const atomic = std.atomic;
const Thread = std.Thread;

pub fn SkipListNode(ValueType: type, allocator: std.mem.Allocator) type {
    const Flag = enum(u16) {
        Init = 0,
        IsHeadNode = 1,
        MarkedForRemoval = (1 << 1),
        FullyLinked = (1 << 2),
    };
    return struct {
        const Self = @This();

        flags_: atomic.Value(Flag),
        height_: u8,
        spinLock_: Thread.Mutex,
        data_: ValueType,
        skip_: std.ArrayList(?*Self),

        pub fn create(node_height: usize, value_data: *const ValueType, option: ?struct { isHead: bool = false }) *Self {
            var flag: atomic.Value(Flag) = undefined;
            flag.store(.Init, .release);
            if (option) |opt| {
                if (opt.isHead) {
                    flag.store(.IsHeadNode, .release);
                }
            }

            var ret = allocator.create(Self) catch unreachable;

            ret.* = Self{
                .flags_ = flag,
                .height_ = @intCast(node_height),
                .spinLock_ = Thread.Mutex{},
                .data_ = value_data.*,
                .skip_ = std.ArrayList(?*Self).init(allocator),
            };
            ret.skip_.appendNTimes(null, node_height) catch unreachable;
            return ret;
        }

        pub fn destroy(self: *Self) void {
            self.skip_.deinit();
            allocator.destroy(self);
        }

        fn copyHead(self: *Self, node: *Self) *Self {
            self.setFlags(node.getFlags());
            for (0..node.height_) |i| {
                self.setSkip(i, node.skip(i));
            }
            return self;
        }

        pub inline fn skip(self: *Self, layer: i32) ?*Self {
            return self.skip_[layer].load(.acquired);
        }

        // next valid node as in the linked list
        fn next(self: *Self) *Self {
            var node: *Self = self.skip(0);
            while (node != null and node.markedForRemoval()) : (node = node.skip(0)) {}
            return node;
        }

        fn setSkip(self: *Self, h: u8, skip_node: *Self) void {
            self.skip_[h].store(skip_node, .release);
        }

        pub fn data(self: *const Self) ValueType {
            return self.data_;
        }
        fn maxLayer(self: *const Self) i32 {
            return self.height_ - 1;
        }
        pub fn height(self: *const Self) i32 {
            return self.height_;
        }

        fn acquireGuard(self: *Self) *Thread.Mutex {
            return &self.spinLock_;
        }

        fn fullyLinked(self: *Self) bool {
            return self.getFlags() & .fullyLinked;
        }
        fn markedForRemoval(self: *Self) bool {
            return self.getFlags() & .markedForRemoval;
        }
        fn isHeadNode(self: *Self) bool {
            return self.getFlags() & .IsHeadNode;
        }

        fn setIsHeadNode(self: *Self) void {
            self.setFlags(@intCast(getFlags() | .IsHeadNode));
        }
        fn setFullyLinked(self: *Self) void {
            self.setFlags(@intCast(getFlags() | .fullyLinked));
        }
        fn setMarkedForRemoval(self: *Self) void {
            self.setFlags(@intCast(getFlags() | .markedForRemoval));
        }
        fn getFlags(self: *const Self) u16 {
            return self.flags_.load(.acquired);
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
            var b_init: atomic.Value(bool) = false;
            var lock: Thread.Mutex = Thread.Mutex{};
            var random_height: Self = Self{};
        };
        if (!Instance.b_init.load(.acquired)) {
            Instance.lock.lock();
            defer Instance.lock.unlock();
            if (!Instance.b_init.load(.acquired)) {
                Instance.random_height.initLookupTable();
                Instance.b_init.store(true, .release);
            }
        }
        return &Instance.random_height;
    }

    pub fn getHeight(self: *Self, maxHeight: i32) i32 {
        std.debug.assert(maxHeight <= kMaxHeight);
        const p = randomProb();
        for (0..maxHeight) |i| {
            if (p < self.lookupTable_[i]) {
                return i + 1;
            }
        }
        return maxHeight;
    }

    pub fn getSizeLimit(self: *Self, height: i32) isize {
        std.debug.assert(height < kMaxHeight);
        return self.sizeLimitTable_[height];
    }

    fn initLookupTable(self: *Self) void {
        // set skip prob = 1/E
        const kProbInv: f64 = std.math.exp(1.0);
        const kProb: f64 = 1.0 / kProbInv;
        const kMaxSizeLimit: isize = std.math.inf(isize);

        var sizeLimit: f64 = 1;
        var p = (1 - kProb);
        self.lookupTable_[0] = p;
        self.sizeLimitTable_[0] = 1;

        var i: i32 = 1;
        while (i < kMaxHeight - 1) : (i += 1) {
            p *= kProb;
            sizeLimit *= kProbInv;
            self.lookupTable_[i] = self.lookupTable_[i - 1] + p;
            self.sizeLimitTable_[i] = if (sizeLimit > std.mach.inf(isize)) std.math.inf(isize) else sizeLimit;
        }
        self.lookupTable_[kMaxHeight - 1] = 1;
        self.sizeLimitTable_[kMaxHeight - 1] = kMaxSizeLimit;
    }

    fn randomProb() f64 {
        const rng = struct {
            var prng = std.Random.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
                break :blk seed;
            });
            const rand = prng.random();
        };
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
            return Self{
                .nodes = NodeAlloc.create(std.ArrayList(*NodeType)) catch unreachable,
            };
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit();
            NodeAlloc.destroy(self.nodes);
        }

        pub fn add(self: *Self, node: *NodeType) void {
            self.lock.lock();
            defer self.lock.unlock();

            if (self.nodes == null) {
                @panic("NodeRecycler hasn't init.");
            } else {
                self.nodes.append(node);
            }
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
            if (!self.dirty.load(.release) or self.refs() > 1) {
                return self.refs.fetch_add(-1, .acq_rel);
            }

            var newNodes: *std.ArrayList(*NodeType) = null;
            var ret: i32 = 0;
            {
                // The order at which we lock, add, swap, is very important for
                // correctness.
                self.lock.lock();
                defer self.lock.unlock();

                ret = self.refs.fetch_add(-1, .acq_rel);
                if (ret == 1) {
                    // When releasing the last reference, it is safe to remove all the
                    // current nodes in the recycler, as we already acquired the lock here
                    // so no more new nodes can be added, even though new accessors may be
                    // added after this.
                    const temp = self.nodes;
                    self.nodes = newNodes;
                    newNodes = temp;
                    self.dirty.store(false, .release);
                }
            }
            // TODO(xliu) should we spawn a thread to do this when there are large
            // number of nodes in the recycler?
            if (newNodes != null) {
                for (newNodes) |node| {
                    node.destroy();
                }
            }
            return ret;
        }

        fn refs(self: *Self) i32 {
            return self.refs_.load(.release);
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
