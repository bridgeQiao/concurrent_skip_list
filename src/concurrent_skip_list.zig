const std = @import("std");
const mem = std.mem;
const atomic = std.atomic;
const Thread = std.Thread;

const skip_list_inc = @import("concurrent_skip_list_inc.zig");

pub fn ConcurrentSkipList(T: type, Comp: *const fn (lhs: *const T, rhs: *const T) bool, NodeAlloc: mem.Allocator, comptime MAX_HEIGHT: i32) type {
    return struct {
        const Self = @This();
        const NodeType = skip_list_inc.SkipListNode(T, NodeAlloc);
        const value_type = T;
        const key_type = T;
        const FindType = struct { first: *NodeType, second: i32 };

        recycler: skip_list_inc.NodeRecycler(NodeType, NodeAlloc),
        head: atomic.Value(*NodeType) = undefined,
        size: atomic.Value(isize) = undefined,

        pub fn init() Self {
            return Self{
                .recycler = skip_list_inc.NodeRecycler(NodeType, NodeAlloc).init(),
                .head = atomic.Value(*NodeType){ .raw = NodeType.create(MAX_HEIGHT, null, .{ .isHead = true }) },
                .size = atomic.Value(isize){ .raw = 0 },
            };
        }

        pub fn deinit(self: *Self) void {
            var current: ?*NodeType = self.head.load(.unordered);
            while (current != null) {
                const tmp = current.?.skip(0);
                current.?.destroy();
                current = tmp;
            }
        }

        pub fn getSize(self: *Self) isize {
            return self.size.load(.relaxed);
        }
        pub fn empty(self: *const Self) bool {
            return self.size() == 0;
        }

        fn greater(data: *const value_type, node: ?*const NodeType) bool {
            return node != null and Comp(node.?.data(), data);
        }

        fn less(data: *const value_type, node: ?*const NodeType) bool {
            return (node == null) or Comp(data, node.?.data());
        }

        fn findInsertionPoint(cur: *NodeType, cur_layer: usize, data: *const value_type, preds: []*NodeType, succs: []?*NodeType) i32 {
            var foundLayer: i32 = -1;
            var pred: ?*NodeType = cur;
            var foundNode: ?*NodeType = null;

            var layer: isize = @intCast(cur_layer);
            while (layer >= 0) : (layer -= 1) {
                const skip_layer: usize = @intCast(layer);
                var node = pred.?.skip(skip_layer);
                while (greater(data, node)) {
                    pred = node;
                    node = node.?.skip(skip_layer);
                }
                if (foundLayer == -1 and !less(data, node)) { // the two keys equal
                    foundLayer = @intCast(layer);
                    foundNode = node;
                }
                preds[skip_layer] = pred.?;

                // if found, succs[0..foundLayer] need to point to the cached foundNode,
                // as foundNode might be deleted at the same time thus pred.skip() can
                // return nullptr or another node.
                succs[skip_layer] = if (foundNode != null) foundNode.? else node;
            }
            return foundLayer;
        }

        fn height(self: *const Self) usize {
            return self.head.load(.acquire).height();
        }

        fn maxLayer(self: *const Self) usize {
            return self.height() - 1;
        }

        fn incrementSize(self: *Self, delta: i32) isize {
            return self.size.fetchAdd(delta, .monotonic) + delta;
        }

        // Returns the node if found, nullptr otherwise.
        pub fn find(self: *Self, data: *const value_type) ?*NodeType {
            var ret = self.findNode(data);
            if (ret.second != 0 and !ret.first.markedForRemoval()) {
                return ret.first;
            }
            return null;
        }

        // lock all the necessary nodes for changing (adding or removing) the list.
        // returns true if all the lock acquired successfully and the related nodes
        // are all validate (not in certain pending states), false otherwise.
        fn lockNodesForChange(nodeHeight: usize, guards: []?*Thread.Mutex, preds: []*NodeType, succs: []?*NodeType, adding: bool) bool {
            var pred: *NodeType = undefined;
            var succ: ?*NodeType = null;
            var prevPred: *NodeType = undefined;
            var valid = true;

            var layer: usize = 0;
            while (valid and layer < nodeHeight) : (layer += 1) {
                pred = preds[layer];
                succ = succs[layer];
                if (pred != prevPred) {
                    guards[layer] = pred.acquireGuard();
                    prevPred = pred;
                }
                valid = !pred.markedForRemoval() and
                    pred.skip(layer) == succ; // check again after locking

                if (adding) { // when adding a node, the succ shouldn't be going away
                    valid = valid and (succ == null or !succ.?.markedForRemoval());
                }
            }

            return valid;
        }

        fn addOrGetData(self: *Self, data: *const value_type) struct { first: *NodeType, second: isize } {
            var preds: [MAX_HEIGHT]*NodeType = undefined;
            var succs: [MAX_HEIGHT]?*NodeType = [1]?*NodeType{null} ** MAX_HEIGHT;
            var newNode: *NodeType = undefined;
            var newSize: isize = 0;
            while (true) {
                var max_layer: usize = 0;
                const layer = self.findInsertionPointGetMaxLayer(data, &preds, &succs, &max_layer);

                if (layer >= 0) {
                    const nodeFound = succs[@intCast(layer)].?;
                    if (nodeFound.markedForRemoval()) {
                        continue; // if it's getting deleted retry finding node.
                    }
                    // wait until fully linked.
                    while (!nodeFound.fullyLinked()) {}
                    return .{ .first = nodeFound, .second = newSize };
                }

                // need to capped at the original height -- the real height may have grown
                const nodeHeight =
                    skip_list_inc.SkipListRandomHeight.instance().getHeight(max_layer + 1);

                var guards = [1]?*Thread.Mutex{null} ** MAX_HEIGHT;
                defer {
                    for (guards) |lock| {
                        if (lock != null) lock.?.unlock();
                    }
                }
                if (!lockNodesForChange(nodeHeight, &guards, &preds, &succs, true)) {
                    continue; // give up the locks and retry until all valid
                }

                // locks acquired and all valid, need to modify the links under the locks.
                newNode = NodeType.create(@intCast(nodeHeight), data, null);
                for (0..@intCast(nodeHeight)) |k| {
                    newNode.setSkip(@intCast(k), succs[k]);
                    preds[k].setSkip(@intCast(k), newNode);
                }

                newNode.setFullyLinked();
                newSize = self.incrementSize(1);
                break;
            }

            const hgt = self.height();
            const sizeLimit =
                skip_list_inc.SkipListRandomHeight.instance().getSizeLimit(hgt);

            if (hgt < MAX_HEIGHT and newSize > sizeLimit) {
                self.growHeight(hgt + 1);
            }
            return .{ .first = newNode, .second = newSize };
        }

        fn remove(self: *Self, data: *const value_type) bool {
            var nodeToDelete: *NodeType = undefined;
            var nodeGuard: ?*Thread.Mutex = null;
            defer {
                if (nodeGuard != null) {
                    nodeGuard.?.unlock();
                }
            }
            var isMarked = false;
            var nodeHeight: usize = 0;
            var preds: [MAX_HEIGHT]*NodeType = undefined;
            var succs: [MAX_HEIGHT]?*NodeType = [1]?*NodeType{null} ** MAX_HEIGHT;

            while (true) {
                var max_layer: usize = 0;
                const layer: i32 = self.findInsertionPointGetMaxLayer(data, &preds, &succs, &max_layer);
                if (!isMarked and (layer < 0 or !okToDelete(succs[@intCast(layer)].?, layer))) {
                    return false;
                }

                if (!isMarked) {
                    nodeToDelete = succs[@intCast(layer)].?;
                    nodeHeight = nodeToDelete.height();
                    if (nodeGuard != null) nodeGuard.?.unlock();
                    nodeGuard = nodeToDelete.acquireGuard();
                    defer {
                        nodeGuard.?.unlock();
                        nodeGuard = null;
                    }
                    if (nodeToDelete.markedForRemoval()) {
                        return false;
                    }
                    nodeToDelete.setMarkedForRemoval();
                    isMarked = true;
                }

                // acquire pred locks from bottom layer up
                var guards = [1]?*Thread.Mutex{null} ** MAX_HEIGHT;
                defer {
                    for (guards) |lock| {
                        if (lock != null) lock.?.unlock();
                    }
                }
                if (!lockNodesForChange(nodeHeight, &guards, &preds, &succs, false)) {
                    continue; // this will unlock all the locks
                }

                var k: i32 = @as(i32, @intCast(nodeHeight)) - 1;
                while (k >= 0) : (k -= 1) {
                    preds[@intCast(k)].setSkip(@intCast(k), nodeToDelete.skip(@intCast(k)));
                }

                _ = self.incrementSize(-1);
                break;
            }
            self.recycle(nodeToDelete);
            return true;
        }

        fn first(self: *const Self) ?*value_type {
            var node = self.head.load(.acquire).skip(0);
            return if (node != null) node.?.data() else null;
        }

        fn last(self: *const Self) ?*value_type {
            var pred = self.head.load(.acquire);
            var node: *NodeType = null;

            var layer: i32 = self.maxLayer();
            while (layer >= 0) : (layer -= 1) {
                node = pred.skip(layer);
                while (node != null) : (node = pred.skip(layer)) {
                    pred = node;
                }
            }
            return if (pred == self.head.load(.relaxed)) null else &pred.data();
        }

        fn okToDelete(candidate: *NodeType, layer: i32) bool {
            return candidate.fullyLinked() and candidate.maxLayer() == layer and
                !candidate.markedForRemoval();
        }

        // find node for insertion/deleting
        fn findInsertionPointGetMaxLayer(self: *const Self, data: *const value_type, preds: []*NodeType, succs: []?*NodeType, max_layer: *usize) i32 {
            max_layer.* = self.maxLayer();
            return findInsertionPoint(self.head.load(.acquire), max_layer.*, data, preds, succs);
        }

        // Find node for access. Returns a paired values:
        // pair.first = the first node that no-less than data value
        // pair.second = 1 when the data value is founded, or 0 otherwise.
        // This is like lower_bound, but not exact: we could have the node marked for
        // removal so still need to check that.
        fn findNode(self: *const Self, data: *const value_type) FindType {
            return findNodeDownRight(self, data);
        }

        // Find node by first stepping down then stepping right. Based on benchmark
        // results, this is slightly faster than findNodeRightDown for better
        // locality on the skipping pointers.
        fn findNodeDownRight(self: *const Self, data: *const value_type) FindType {
            var pred = self.head.load(.acquire);
            var ht = pred.height();
            var node: ?*NodeType = null;

            var found = false;
            while (!found) {
                // stepping down
                if (ht > 0) {
                    node = pred.skip(ht - 1);
                    while (ht > 0 and less(data, node)) : (ht -= 1) {
                        node = pred.skip(ht - 1);
                    }
                }
                if (ht == 0) {
                    return .{ .first = undefined, .second = 0 }; // not found
                }
                // node <= data now, but we need to fix up ht
                ht -= 1;

                // stepping right
                while (greater(data, node)) {
                    pred = node.?;
                    node = node.?.skip(ht);
                }
                found = !less(data, node);
            }
            return .{ .first = node.?, .second = @intFromBool(found) };
        }

        fn lower_bound(self: *const Self, data: *const value_type) *NodeType {
            var node = self.findNode(data).first;
            while (node != null and node.markedForRemoval()) {
                node = node.skip(0);
            }
            return node;
        }

        fn growHeight(self: *Self, node_height: usize) void {
            var oldHead = self.head.load(.acquire);
            if (oldHead.height() >= node_height) { // someone else already did this
                return;
            }

            var newHead =
                NodeType.create(@intCast(node_height), undefined, .{ .isHead = true });

            { // need to guard the head node in case others are adding/removing
                // nodes linked to the head.
                var g = oldHead.acquireGuard();
                g.lock();
                defer g.unlock();
                _ = newHead.copyHead(oldHead);
                const expected = oldHead;
                if (self.head.cmpxchgStrong(expected, newHead, .release, .monotonic) != null) {
                    // if someone has already done the swap, just return.
                    newHead.destroy();
                    return;
                }
                oldHead.setMarkedForRemoval();
            }
            self.recycle(oldHead);
        }

        fn recycle(self: *Self, node: *NodeType) void {
            self.recycler.add(node);
        }
    };
}

pub fn Accessor(SkipListType: type) type {
    return struct {
        const Self = @This();
        const size_type = isize;
        const value_type = SkipListType.value_type;
        const key_type = SkipListType.key_type;
        const NodeType = SkipListType.NodeType;

        sl_: *SkipListType,

        pub fn init(sl: *SkipListType) Self {
            const ret = Self{
                .sl_ = sl,
            };
            _ = ret.sl_.recycler.addRef();
            return ret;
        }

        pub fn deinit(self: *Self) void {
            _ = self.sl_.recycler.releaseRef();
        }

        pub fn empty(self: *const Self) bool {
            return self.sl_.size() == 0;
        }
        pub fn size(self: *const Self) isize {
            return self.sl_.size();
        }
        pub fn max_size() size_type {
            return std.math.inf(size_type);
        }

        // returns end() if the value is not in the list, otherwise returns an
        // iterator pointing to the data, and it's guaranteed that the data is valid
        // as far as the Accessor is hold.
        pub fn find(self: *const Self, value: *const key_type) ?*NodeType {
            return self.sl_.find(value);
        }

        pub fn count(data: *const key_type) size_type {
            return contains(data);
        }

        pub fn begin(self: *const Self) *NodeType {
            const head = self.sl_.head.load(.acquire);
            return head.next();
        }
        pub fn end() *NodeType {
            return null;
        }

        pub fn insert(self: *Self, data: *NodeType) struct { first: *NodeType, second: bool } {
            return self.sl_.addOrGetData(data);
        }
        pub fn erase(self: *Self, data: *const key_type) isize {
            return self.sl_.remove(data);
        }

        pub fn lower_bound(self: *const Self, data: *const key_type) *NodeType {
            return self.sl_.lower_bound(data);
        }

        pub fn height(self: *const Self) isize {
            return self.sl_.height();
        }

        // first() returns pointer to the first element in the skiplist, or
        // nullptr if empty.
        //
        // last() returns the pointer to the last element in the skiplist,
        // nullptr if list is empty.
        //
        // Note: As concurrent writing can happen, first() is not
        //   guaranteed to be the min_element() in the list. Similarly
        //   last() is not guaranteed to be the max_element(), and both of them can
        //   be invalid (i.e. nullptr), so we name them differently from front() and
        //   tail() here.
        pub fn first(self: *const Self) ?*const key_type {
            return self.sl_.first();
        }
        pub fn last(self: *const Self) *const key_type {
            return self.sl_.last();
        }

        // Try to remove the last element in the skip list.
        //
        // Returns true if we removed it, false if either the list is empty
        // or a race condition happened (i.e. the used-to-be last element
        // was already removed by another thread).
        pub fn pop_back(self: *Self) bool {
            const last_node = self.sl_.last();
            return if (last_node != null) self.sl_.remove(*last_node) else false;
        }

        pub fn addOrGetData(self: *Self, data: *const key_type) struct { first: *key_type, second: bool } {
            const ret = self.sl_.addOrGetData(data);
            return .{ .first = &ret.first.data(), .second = ret.second };
        }

        pub fn skiplist(self: *const Self) *SkipListType {
            return self.sl_;
        }

        // legacy interfaces
        // TODO:(xliu) remove these.
        // Returns true if the node is added successfully, false if not, i.e. the
        // node with the same key already existed in the list.
        pub fn contains(self: *Self, data: *const key_type) bool {
            return self.sl_.find(data) != null;
        }
        pub fn add(self: *Self, data: *const key_type) bool {
            return self.sl_.addOrGetData(data).second != 0;
        }
        pub fn remove(self: *Self, data: *const key_type) bool {
            return self.sl_.remove(data);
        }
    };
}
