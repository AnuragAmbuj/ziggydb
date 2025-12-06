const std = @import("std");
const z = @import("ziggydb");
const TableBuilder = z.sstable.builder.TableBuilder;
const TableReader = z.sstable.reader.TableReader;
const MemTable = z.memtable.MemTable;
const MergingIterator = z.merge_iter.MergingIterator;
const Arena = z.util.arena.Arena;

test "merge_iter: basic merge memtable + sstable" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir_path, "test.sst" });
    defer std.testing.allocator.free(path);

    // 1. Write SSTable
    {
        var tb = try TableBuilder.create(std.testing.allocator, path, 4096);
        defer tb.deinit();
        try tb.add("apple", "red");
        try tb.add("cherry", "red");
        try tb.finish();
    }

    // 2. Setup MemTable
    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();
    var mem = try MemTable.init(&arena);
    try mem.put(10, "banana", "yellow");
    try mem.put(11, "date", "brown");

    // 3. Setup MergingIterator
    // Manually construct iters and readers lists
    var readers = std.ArrayList(*TableReader).init(std.testing.allocator);
    defer {
        for (readers.items) |r| { r.close(); std.testing.allocator.destroy(r); }
        readers.deinit();
    }
    var sst_iters = std.ArrayList(TableReader.Iter).init(std.testing.allocator);
    defer sst_iters.deinit();

    const tr_ptr = try std.testing.allocator.create(TableReader);
    tr_ptr.* = try TableReader.open(std.testing.allocator, path);
    try readers.append(tr_ptr);
    try sst_iters.append(try TableReader.Iter.init(tr_ptr, "", ""));

    const mem_iter = MemTable.Iter.init(&mem, 100, "", ""); // read_ts high enough

    // NOTE: We pass copies of the lists to init; it takes ownership.
    // So we use .clone() or similar? `MergingIterator.init` takes arguments by value (struct copying ArrayList).
    // NO, ArrayList is a struct. If we pass it, we pass the struct.
    // The struct contains pointer to items.
    // If we simply pass `readers` variable, it is copied.
    // But `readers` local variable will defer deinit()!!
    // We should NOT defer deinit() if we pass ownership!
    // Or we should pass newly initialized lists.
    
    // Correct way:
    var readers_owned = std.ArrayList(*TableReader).init(std.testing.allocator);
    errdefer readers_owned.deinit(); 
    // Fill it
    const tr_ptr2 = try std.testing.allocator.create(TableReader);
    tr_ptr2.* = try TableReader.open(std.testing.allocator, path);
    try readers_owned.append(tr_ptr2);

    var sst_iters_owned = std.ArrayList(TableReader.Iter).init(std.testing.allocator);
    errdefer sst_iters_owned.deinit();
    try sst_iters_owned.append(try TableReader.Iter.init(tr_ptr2, "", ""));

    var iter = try MergingIterator.init(std.testing.allocator, mem_iter, sst_iters_owned, readers_owned);
    defer iter.deinit();

    // Verify order: apple, banana, cherry, date
    var e = (try iter.next()) orelse return error.NotFound;
    try std.testing.expectEqualStrings("apple", e.key);
    try std.testing.expectEqualStrings("red", e.value);

    e = (try iter.next()) orelse return error.NotFound;
    try std.testing.expectEqualStrings("banana", e.key);
    try std.testing.expectEqualStrings("yellow", e.value);

    e = (try iter.next()) orelse return error.NotFound;
    try std.testing.expectEqualStrings("cherry", e.key);
    try std.testing.expectEqualStrings("red", e.value);

    e = (try iter.next()) orelse return error.NotFound;
    try std.testing.expectEqualStrings("date", e.key);
    try std.testing.expectEqualStrings("brown", e.value);

    try std.testing.expect((try iter.next()) == null);
}

test "merge_iter: shadowing and deletions" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir_path, "shadow.sst" });
    defer std.testing.allocator.free(path);

    // 1. Write SSTable: key1=old, key2=keep, key3=delete_me
    {
        var tb = try TableBuilder.create(std.testing.allocator, path, 4096);
        defer tb.deinit();
        try tb.add("key1", "old_val");
        try tb.add("key2", "keep_val");
        try tb.add("key3", "val3");
        try tb.finish();
    }

    // 2. Setup MemTable: key1=new, key3=DEL
    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();
    var mem = try MemTable.init(&arena);
    try mem.put(10, "key1", "new_val");
    try mem.del(11, "key3");

    // 3. MergingIterator
    var readers_owned = std.ArrayList(*TableReader).init(std.testing.allocator);
    const tr_ptr = try std.testing.allocator.create(TableReader);
    tr_ptr.* = try TableReader.open(std.testing.allocator, path);
    try readers_owned.append(tr_ptr);

    var sst_iters_owned = std.ArrayList(TableReader.Iter).init(std.testing.allocator);
    try sst_iters_owned.append(try TableReader.Iter.init(tr_ptr, "", ""));

    var iter = try MergingIterator.init(std.testing.allocator, MemTable.Iter.init(&mem, 100, "", ""), sst_iters_owned, readers_owned);
    defer iter.deinit();

    // Verify: key1 should be new_val
    var e = (try iter.next()) orelse return error.NotFound;
    try std.testing.expectEqualStrings("key1", e.key);
    try std.testing.expectEqualStrings("new_val", e.value);

    // Verify: key2 should be keep_val
    e = (try iter.next()) orelse return error.NotFound;
    try std.testing.expectEqualStrings("key2", e.key);
    try std.testing.expectEqualStrings("keep_val", e.value);

    // Verify: key3 should NOT be returned (deleted)
    try std.testing.expect((try iter.next()) == null);
}
