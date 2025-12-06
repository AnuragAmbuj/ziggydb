const std = @import("std");

/// A thread-safe LRU Cache.
/// Key must be hashing/equality compatible (e.g. strings or structs).
/// Value must be managed by the cache (freed on eviction).
/// For Block Cache, Key = struct { file_id: u64, offset: u64 }, Value = []u8 (block bytes).
pub fn LRUCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        
        // Doubly-linked list node
        pub const Node = struct {
            key: K,
            value: V,
            charge: usize,
            next: ?*Node,
            prev: ?*Node,
        };

        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex,
        
        capacity: usize,
        usage: usize,
        
        map: std.AutoHashMap(K, *Node),
        head: ?*Node, // Most recent
        tail: ?*Node, // Least recent

        pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
            return .{
                .allocator = allocator,
                .mutex = .{},
                .capacity = capacity,
                .usage = 0,
                .map = std.AutoHashMap(K, *Node).init(allocator),
                .head = null,
                .tail = null,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.valueIterator();
            while (it.next()) |node_ptr| {
                const node = node_ptr.*;
                // User is responsible for deep freeing K/V if needed?
                // For simplicity, we assume V is []u8 owned by Node, and K is POD.
                // If V needs special cleanup, we need a callback.
                // Assuming V is just allocator-allocated slice.
                self.allocator.free(node.value);
                self.allocator.destroy(node);
            }
            self.map.deinit();
        }

        /// Insert item. If exists, update value and move to front.
        /// Takes ownership of `value` (must be allocated with `self.allocator`).
        pub fn insert(self: *Self, key: K, value: V, charge: usize) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.get(key)) |node| {
                // Update existing
                self.usage -= node.charge;
                self.allocator.free(node.value); // free old value
                
                node.value = value;
                node.charge = charge;
                self.usage += charge;
                
                self.moveToHead(node);
            } else {
                // Create new
                const node = try self.allocator.create(Node);
                node.* = .{
                    .key = key,
                    .value = value,
                    .charge = charge,
                    .next = null,
                    .prev = null,
                };
                
                try self.map.put(key, node);
                self.usage += charge;
                self.attachToHead(node);
            }

            // Evict if needed
            while (self.usage > self.capacity and self.tail != null) {
                const victim = self.tail.?;
                if (victim == self.head) {
                     // only one item, but still over capacity?
                     // Hard eviction.
                }
                self.removeNode(victim);
                _ = self.map.remove(victim.key);
                self.usage -= victim.charge;
                
                self.allocator.free(victim.value);
                self.allocator.destroy(victim);
            }
        }

        /// Create a copy of the value if found.
        /// Caller owns the returned copy.
        /// We copy because returning a pointer is unsafe (eviction could happen).
        /// Or we could use ref-counting for detailed zero-copy, but copy is simpler for V1.
        pub fn lookup(self: *Self, key: K) ?[]const u8 {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.get(key)) |node| {
                self.moveToHead(node);
                // We return a copy to stay thread safe outside lock
                return self.allocator.dupe(u8, node.value) catch null;
            }
            return null;
        }

        fn checkConsistency(self: *Self) void {
             // Debug helper
             _ = self;
        }

        // --- List Helpers ---

        fn attachToHead(self: *Self, node: *Node) void {
            if (self.head) |h| {
                node.next = h;
                h.prev = node;
                self.head = node;
            } else {
                self.head = node;
                self.tail = node;
            }
        }

        fn removeNode(self: *Self, node: *Node) void {
            if (node.prev) |p| p.next = node.next else self.head = node.next;
            if (node.next) |n| n.prev = node.prev else self.tail = node.prev;
            node.next = null;
            node.prev = null;
        }

        fn moveToHead(self: *Self, node: *Node) void {
            if (self.head == node) return;
            self.removeNode(node);
            self.attachToHead(node);
        }
    };
}
