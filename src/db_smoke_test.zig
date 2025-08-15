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