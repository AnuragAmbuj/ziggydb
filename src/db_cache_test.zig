const std = @import("std");
const z = @import("root.zig");
const Options = z.options.Options;

test "DB with Block Cache Integration" {
    const allocator = std.testing.allocator;
    const path = "test_db_cache_integration";
    
    // Cleanup setup
    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const opts = Options{
        .path = path,
        .memtable_bytes = 1024 * 1024,
        .block_size = 1024,
        .block_cache_bytes = 4 * 1024 * 1024, // 4MB Cache
    };

    var db = try z.db.DB.open(allocator, opts);
    
    // 1. Insert data (enough to cause flushing if we wanted, but let's flush manually)
    // We want to create SSTables so reading goes through Cache.
    const key = "key_for_cache";
    const val = "value_that_should_be_cached_0000000000000000000000000000000"; // > 32 bytes

    try db.put(key, val);
    
    // Flush to SST
    try db.flush();
    
    // 2. Read (Cold) - Should load block into cache
    if (try db.get(key)) |v| {
        try std.testing.expectEqualStrings(val, v);
        allocator.free(v);
    } else {
        return error.NotFound;
    }
    
    // 3. Read (Hot) - Should serve from cache
    if (try db.get(key)) |v| {
        try std.testing.expectEqualStrings(val, v);
        allocator.free(v);
    } else {
        return error.NotFound;
    }
    
    // 4. Compact - Should involve cache reading
    try db.compact(&.{}); // Dummy compaction or real if we had multiple files
    
    // Clean close
    db.close();
    allocator.destroy(db);
}
