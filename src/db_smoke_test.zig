const std = @import("std");
const z = @import("ziggydb");
const DB = @import("db.zig").DB;
const Options = @import("options.zig").Options;

test "db: put/get + flush" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var db = try DB.open(gpa.allocator(), .{
        .path = tmp.dir_path,
        .memtable_bytes = 8 * 1024, // small to force flush
        .block_size = 4096,
        .fsync_on_commit = false,
    });
    defer db.close();

    try db.put("a", "1");
    try db.put("b", "2");
    try db.put("c", "3");

    // memtable read should work
    try std.testing.expectEqualStrings("2", (try db.get("b")) orelse return error.Miss);

    // fill memtable to trigger flush
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var keybuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&keybuf, "k{d}", .{i});
        try db.put(k, "x");
    }

    // still able to read from memtable
    try std.testing.expectEqualStrings("1", (try db.get("a")) orelse return error.Miss);
}

test "db: scan integration" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const opts = z.db.Options{
        .path = tmp.dir_path,
        .memtable_bytes = 4096, // manually flush
        .block_size = 4096,
        .fsync_on_commit = false,
    };
    var db = try z.db.DB.open(std.testing.allocator, opts);
    defer db.close();

    // 1. Fill data: SST1 [a, c], SST2 [b, d], Mem [e]
    // Write SST1
    try db.put("a", "val_a");
    try db.put("c", "val_c");
    try db.flushNow();
    
    // Write SST2
    try db.put("b", "val_b");
    try db.put("d", "val_d");
    try db.flushNow();

    // Write MemTable
    try db.put("e", "val_e");
    
    // 2. Scan All
    {
        var it = try db.scan("", "");
        defer it.deinit();

        var e = (try it.next()) orelse return error.NotFound;
        try std.testing.expectEqualStrings("a", e.key);
        try std.testing.expectEqualStrings("val_a", e.value);

        e = (try it.next()) orelse return error.NotFound;
        try std.testing.expectEqualStrings("b", e.key);
        try std.testing.expectEqualStrings("val_b", e.value);

        e = (try it.next()) orelse return error.NotFound;
        try std.testing.expectEqualStrings("c", e.key);
        try std.testing.expectEqualStrings("val_c", e.value);

        e = (try it.next()) orelse return error.NotFound;
        try std.testing.expectEqualStrings("d", e.key);
        try std.testing.expectEqualStrings("val_d", e.value);

        e = (try it.next()) orelse return error.NotFound;
        try std.testing.expectEqualStrings("e", e.key);
        try std.testing.expectEqualStrings("val_e", e.value);

        try std.testing.expect((try it.next()) == null);
    }
    
    // 3. Scan Range [b, d) -> b, c
    {
        var it = try db.scan("b", "d");
        defer it.deinit();

        var e = (try it.next()) orelse return error.NotFound;
        try std.testing.expectEqualStrings("b", e.key);
        
        e = (try it.next()) orelse return error.NotFound;
        try std.testing.expectEqualStrings("c", e.key);
        
        try std.testing.expect((try it.next()) == null);
    }
}