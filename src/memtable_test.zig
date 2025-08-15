const std = @import("std");
const Arena = @import("util/arena.zig").Arena;
const MemTable = @import("memtable.zig").MemTable;
const Kind = @import("memtable.zig").Kind;

fn makeMT() !struct{ arena: Arena, mt: MemTable } {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit(); // not returned; only used to allocate Arena pages
    // _ = gpa; // silence unused (tests create their own arenas below)
    return error.Unused;
}

// Test helpers create dedicated arenas per test
test "memtable put/get basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = try Arena.init(gpa.allocator(), 64 * 1024);
    defer arena.deinit();

    var mt = try MemTable.init(&arena);

    try mt.put(10, "a", "1");
    try mt.put(11, "b", "2");
    try mt.put(12, "a", "3");

    // read_ts before latest "a"
    try std.testing.expectEqualStrings("1", (try mt.get(10, "a")) orelse return error.Missing);
    // at 12 we see latest
    try std.testing.expectEqualStrings("3", (try mt.get(12, "a")) orelse return error.Missing);
    // "c" absent
    try std.testing.expect((try mt.get(99, "c")) == null);
}

test "memtable delete visibility" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = try Arena.init(gpa.allocator(), 64 * 1024);
    defer arena.deinit();

    var mt = try MemTable.init(&arena);

    try mt.put(5, "k", "v1");
    try mt.del(7, "k");

    // before delete, visible
    try std.testing.expectEqualStrings("v1", (try mt.get(6, "k")) orelse return error.Miss);
    // after delete, gone
    try std.testing.expect((try mt.get(7, "k")) == null);
    try std.testing.expect((try mt.get(100, "k")) == null);
}

test "memtable iterator range and MVCC" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = try Arena.init(gpa.allocator(), 256 * 1024);
    defer arena.deinit();

    var mt = try MemTable.init(&arena);

    try mt.put(1, "a", "1");
    try mt.put(2, "b", "1");
    try mt.put(3, "c", "1");
    try mt.put(4, "b", "2"); // newer
    try mt.del(5, "c");      // tombstone newer than read_ts

    // snapshot at 3: should see a=1, b=1, c=1
    var it = MemTable.Iter.init(&mt, 3, "a", "z");
    const e1 = (it.next()) orelse return error.E1;
    try std.testing.expectEqualStrings("a", e1.user_key);
    try std.testing.expectEqual(Kind.Put, e1.kind);
    try std.testing.expectEqualStrings("1", e1.value);

    const e2 = (it.next()) orelse return error.E2;
    try std.testing.expectEqualStrings("b", e2.user_key);
    try std.testing.expectEqualStrings("1", e2.value);

    const e3 = (it.next()) orelse return error.E3;
    try std.testing.expectEqualStrings("c", e3.user_key);
    try std.testing.expectEqualStrings("1", e3.value);

    try std.testing.expect(it.next() == null);

    // snapshot at 6: should see a=1, b=2, c is deleted
    var it2 = MemTable.Iter.init(&mt, 6, "a", "z");
    const f1 = (it2.next()) orelse return error.F1;
    try std.testing.expectEqualStrings("a", f1.user_key);
    try std.testing.expectEqualStrings("1", f1.value);

    const f2 = (it2.next()) orelse return error.F2;
    try std.testing.expectEqualStrings("b", f2.user_key);
    try std.testing.expectEqualStrings("2", f2.value);

    try std.testing.expect(it2.next() == null);
}