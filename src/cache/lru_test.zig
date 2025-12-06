const std = @import("std");
const testing = std.testing;
const LRUCache = @import("lru.zig").LRUCache;

test "LRU Cache - Basic Operations" {
    const allocator = testing.allocator;
    // Cap: 100 bytes.
    var cache = LRUCache(u64, []u8).init(allocator, 100);
    defer cache.deinit();

    const v1 = try allocator.dupe(u8, "hello");
    try cache.insert(1, v1, 5); // charge 5

    const res = cache.lookup(1);
    try testing.expect(res != null);
    try testing.expectEqualStrings("hello", res.?);
    allocator.free(res.?);
}

test "LRU Cache - Eviction" {
    const allocator = testing.allocator;
    var cache = LRUCache(u64, []u8).init(allocator, 10); 
    defer cache.deinit();

    // Insert A (size 4)
    const v1 = try allocator.dupe(u8, "AAAA");
    try cache.insert(1, v1, 4); // usage 4

    // Insert B (size 4)
    const v2 = try allocator.dupe(u8, "BBBB");
    try cache.insert(2, v2, 4); // usage 8

    // A is oldest
    
    // Insert C (size 4) -> Usage 12 > 10. Evict A.
    const v3 = try allocator.dupe(u8, "CCCC");
    try cache.insert(3, v3, 4); // A evicted. Usage = 8 (B, C).

    try testing.expect(cache.lookup(1) == null);
    
    const rb = cache.lookup(2);
    try testing.expect(rb != null);
    allocator.free(rb.?);
    
    const rc = cache.lookup(3);
    try testing.expect(rc != null);
    allocator.free(rc.?);
}

test "LRU Cache - Update Refresh" {
    const allocator = testing.allocator;
    var cache = LRUCache(u64, []u8).init(allocator, 10);
    defer cache.deinit();

    const v1 = try allocator.dupe(u8, "AAAA");
    try cache.insert(1, v1, 4);
    
    const v2 = try allocator.dupe(u8, "BBBB");
    try cache.insert(2, v2, 4);
    
    // Access 1 -> 1 becomes newest. 2 is oldest.
    const r1 = cache.lookup(1);
    allocator.free(r1.?);
    
    // Insert C -> Evicts 2
    const v3 = try allocator.dupe(u8, "CCCC");
    try cache.insert(3, v3, 4); 
    
    try testing.expect(cache.lookup(2) == null);
    const res_final = cache.lookup(1);
    try testing.expect(res_final != null);
    allocator.free(res_final.?);
}
