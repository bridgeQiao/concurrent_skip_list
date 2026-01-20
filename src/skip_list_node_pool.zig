const std = @import("std");

pub fn NodeBlock(comptime NodeType: type, comptime BlockSize: usize) type {
    return struct {
        const Self = @This();

        const InnerNode = struct {
            data: NodeType,
            index: usize,
            block: *Self,
        };

        nodes: [BlockSize]InnerNode = undefined,
        free_flag: [BlockSize]bool = [_]bool{true} ** BlockSize,
        used: usize = 0,
        node_mutex: std.Thread.Mutex = .{},
        list_node: std.DoublyLinkedList.Node = .{},

        pub fn init() Self {
            return Self{};
        }

        pub fn allocate(self: *Self) ?*InnerNode {
            self.node_mutex.lock();
            defer self.node_mutex.unlock();

            if (self.used < BlockSize) {
                var idx: usize = 0;
                while (!self.free_flag[idx]) : (idx += 1) {}
                self.free_flag[idx] = false;
                const node = &self.nodes[idx];
                node.block = self;
                node.index = idx;
                self.used += 1;
                return node;
            } else {
                return null;
            }
        }

        pub fn free(self: *Self, node: *InnerNode) void {
            self.node_mutex.lock();
            defer self.node_mutex.unlock();

            self.free_flag[node.index] = true;
            self.used -= 1;
        }
    };
}

pub fn SkipListNodePool(comptime NodeType: type) type {
    return struct {
        const Self = @This();
        const BlockSize: usize = 64;

        allocator_: std.mem.Allocator,
        blocks: std.DoublyLinkedList = .{},
        data_mutex: std.Thread.Mutex = .{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator_ = allocator,
            };
        }

        pub fn allocate(self: *Self) !*NodeType {
            {
                // find a valid node
                self.data_mutex.lock();
                defer self.data_mutex.unlock();

                var block_node = self.blocks.first;
                while (block_node) |bn| : (block_node = bn.next) {
                    const block: *NodeBlock(NodeType, BlockSize) = @fieldParentPtr("list_node", bn);
                    if (block.allocate()) |node| {
                        return &node.data;
                    }
                }
            }
            // no valid node found, create a new block
            {
                var block = try self.allocator_.create(NodeBlock(NodeType, BlockSize));
                block.* = NodeBlock(NodeType, BlockSize).init();
                {
                    self.data_mutex.lock();
                    defer self.data_mutex.unlock();
                    self.blocks.append(&block.list_node);
                }

                // allocate from the free_nodes
                if (block.allocate()) |node| {
                    return &node.data;
                } else {
                    return error.OutOfMemory;
                }
            }
        }

        pub fn deinit(self: *Self) void {
            while (self.blocks.popFirst()) |block_node| {
                const block: *NodeBlock(NodeType, BlockSize) = @fieldParentPtr("list_node", block_node);
                self.allocator_.destroy(block);
            }
        }

        pub fn free(self: *Self, node: *NodeType) void {
            const inner_node: *NodeBlock(NodeType, BlockSize).InnerNode = @fieldParentPtr("data", node);
            const block = inner_node.block;
            block.free(inner_node);
            {
                self.data_mutex.lock();
                defer self.data_mutex.unlock();
                // optional: free the block if it's empty
                if (block.used == 0) {
                    self.blocks.remove(&block.list_node);
                    self.allocator_.destroy(block);
                    std.debug.print("debug: release block\n", .{});
                } else {
                    std.debug.print("debug: use {}", .{block.used});
                }
            }
        }
    };
}
