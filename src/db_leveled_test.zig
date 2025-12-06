const std = @import("std");
const z = @import("ziggydb");
const DB = z.db.DB;

test "db: leveled compaction L0 -> L1" {
    const tmp = std.testing.tmpDir({});
    defer tmp.cleanup();

    const opts = z.db.Options{
        .path = tmp.dir_path,
        .memtable_bytes = 4096,
        .block_size = 4096,
        .fsync_on_commit = false,
    };
    var db = try DB.open(std.testing.allocator, opts);
    defer db.close();

    // 1. Flush multiple files to L0
    try db.put("a", "1");
    try db.flushNow(); // L0 file 1
    
    try db.put("b", "2");
    try db.flushNow(); // L0 file 2

    try db.put("c", "3");
    try db.flushNow(); // L0 file 3
    
    try db.put("d", "4");
    try db.flushNow(); // L0 file 4
    
    try db.put("e", "5");
    try db.flushNow(); // L0 file 5
    
    // Verify L0 count
    var counts = db.getLevelCounts();
    // After 5 flushes, 4 triggered compaction. L0 should be 1 (the 5th file).
    try std.testing.expectEqual(@as(usize, 1), counts[0]);
    // L1 should have at least 1 file (from merger of 1-4)
    try std.testing.expect(counts[1] >= 1);

    // 2. Trigger Compaction (Manual) - Should be no-op (score 0.25)
    try db.compact({});

    // 3. Verify counts unchanged
    counts = db.getLevelCounts();
    try std.testing.expectEqual(@as(usize, 1), counts[0]);
    try std.testing.expect(counts[1] >= 1);
    
    // 4. Verify Data Validity
    if (try db.get("a")) |v| {
        defer std.testing.allocator.free(v);
        try std.testing.expectEqualStrings("1", v);
    } else return error.NotFound;
    
    if (try db.get("b")) |v| {
        defer std.testing.allocator.free(v);
        try std.testing.expectEqualStrings("2", v);
    } else return error.NotFound;

    // 5. Verify Manifest Persistence (Critical)
    db.close();
    
    // Reopen
    var db2 = try DB.open(std.testing.allocator, opts);
    defer db2.close();
    
    // Verify L0 has 1 file (from 5th flush), L1 has files (from 1-4)
    const c2 = db2.getLevelCounts();
    // Use expectEqual for strict checking
    try std.testing.expectEqual(@as(usize, 1), c2[0]);
    try std.testing.expect(c2[1] >= 1);
    
    // Check data
    if (try db2.get("a")) |v| {
        defer std.testing.allocator.free(v);
        try std.testing.expectEqualStrings("1", v);
    } else return error.NotFound;
}
