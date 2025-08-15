const std = @import("std");
const z = @import("ziggydb");

const DB = z.db.DB;
const Options = z.options.Options;

test "db recovery: WAL-only (no flush)" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Big memtable so we don't flush. fsync to ensure WAL durability.
    var db = try DB.open(gpa.allocator(), .{
        .path = tmp.dir_path,
        .memtable_bytes = 8 * 1024 * 1024,
        .block_size = 4096,
        .fsync_on_commit = true,
    });
    defer db.close();

    try db.put("a", "1");
    try db.put("b", "2");
    try db.del("a");
    try db.put("c", "3");

    // Close, then reopen to force recovery from WAL.
    db.close();

    var db2 = try DB.open(gpa.allocator(), .{
        .path = tmp.dir_path,
        .memtable_bytes = 8 * 1024 * 1024,
        .block_size = 4096,
        .fsync_on_commit = true,
    });
    defer db2.close();

    // 'a' was deleted, others persist via WAL replay.
    try std.testing.expect((try db2.get("a")) == null);
    try std.testing.expectEqualStrings("2", (try db2.get("b")) orelse return error.MissB);
    try std.testing.expectEqualStrings("3", (try db2.get("c")) orelse return error.MissC);
}

test "db recovery: with SST present (newest-first read)" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Tiny memtable so we flush to SST quickly. (fsync not critical here)
    var db = try DB.open(gpa.allocator(), .{
        .path = tmp.dir_path,
        .memtable_bytes = 4 * 1024, // small to force a flush
        .block_size = 1024,
        .fsync_on_commit = false,
    });
    defer db.close();

    // Write enough keys to exceed memtable and trigger a flush
    {
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            var kb: [24]u8 = undefined;
            const key = try std.fmt.bufPrint(&kb, "k{d}", .{i});
            try db.put(key, "x");
        }
    }

    // Overwrite one key after flush to ensure newest value wins post-recovery
    try db.put("k42", "y");

    // Close and reopen: should read from memtable (replayed WAL) or SSTs
    db.close();

    var db2 = try DB.open(gpa.allocator(), .{
        .path = tmp.dir_path,
        .memtable_bytes = 4 * 1024,
        .block_size = 1024,
        .fsync_on_commit = false,
    });
    defer db2.close();

    // A key that’s definitely in the flushed SST:
    try std.testing.expectEqualStrings("x", (try db2.get("k7")) orelse return error.MissK7);

    // Overwritten key should read the newer value ("y")
    try std.testing.expectEqualStrings("y", (try db2.get("k42")) orelse return error.MissK42);
}