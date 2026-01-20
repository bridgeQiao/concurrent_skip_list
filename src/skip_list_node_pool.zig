const std = @import("std");

pub fn NodeBlock(comptime NodeType: type, comptime BlockSize: usize) type {
    return struct {
        const Self = @This();

        nodes: [BlockSize]NodeType = undefined,
        used: usize = 0,
        list_node: std.DoublyLinkedList.Node = .{},

        pub fn init() Self {
            return Self{};
        }

        pub fn allocate(self: *Self) ?*NodeType {
            if (self.used < BlockSize) {
                const node = &self.nodes[self.used];
                self.used += 1;
                return node;
            } else {
                return null;
            }
        }
    };
}

pub fn SkipListNodePool(comptime NodeType: type) type {
    return struct {
        const Self = @This();
        const BlockSize: usize = 64;

        allocator_: std.mem.Allocator,
        blocks: std.DoublyLinkedList = .{},
        free_nodes: std.DoublyLinkedList = .{},
        data_mutex: std.Thread.Mutex = .{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator_ = allocator,
            };
        }

        pub fn allocate(self: *Self) !*NodeType {
            self.data_mutex.lock();
            defer self.data_mutex.unlock();

            if (self.free_nodes.popFirst()) |node| {
                return @fieldParentPtr("list_node", node);
            } else {
                // allocate a new block
                var block = try self.allocator_.create(NodeBlock(NodeType, BlockSize));
                block.* = NodeBlock(NodeType, BlockSize).init();
                self.blocks.append(&block.list_node);
                // add all nodes in the block to free_nodes
                for (block.nodes[0..]) |*node| {
                    self.free_nodes.append(&node.list_node);
                }
                // allocate from the free_nodes
                const node = self.free_nodes.popFirst() orelse unreachable;
                return @fieldParentPtr("list_node", node);
            }
        }

        pub fn deinit(self: *Self) void {
            while (self.blocks.popFirst()) |block_node| {
                const block: *NodeBlock(NodeType, BlockSize) = @fieldParentPtr("list_node", block_node);
                self.allocator_.destroy(block);
            }
        }

        pub fn free(self: *Self, node: *NodeType) void {
            self.data_mutex.lock();
            defer self.data_mutex.unlock();

            self.free_nodes.prepend(&node.list_node);
        }

        pub fn freeList(self: *Self, list: *std.DoublyLinkedList) void {
            self.data_mutex.lock();
            defer self.data_mutex.unlock();

            self.free_nodes.concatByMoving(list);
        }
    };
}
