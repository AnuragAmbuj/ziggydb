const std = @import("std");
const z = @import("ziggydb");
const TableBuilder = z.sstable.builder.TableBuilder;
const TableReader = z.sstable.reader.TableReader;

test "sstable: builder -> reader roundtrip" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir_path, "test.sst" });
    defer std.testing.allocator.free(path);

    // 1. Write SSTable
    {
        var tb = try TableBuilder.create(std.testing.allocator, path, 4096);
        defer tb.deinit();

        try tb.add("key1", "value1");
        try tb.add("key2", "value2");
        try tb.add("key3", "value3");
        try tb.finish();
    }

    // 2. Read SSTable
    {
        var tr = try TableReader.open(std.testing.allocator, path);
        defer tr.close();

        // Test existing keys
        const v1 = (try tr.get("key1", std.testing.allocator)) orelse return error.NotFound;
        defer std.testing.allocator.free(v1);
        try std.testing.expectEqualStrings("value1", v1);

        const v2 = (try tr.get("key2", std.testing.allocator)) orelse return error.NotFound;
        defer std.testing.allocator.free(v2);
        try std.testing.expectEqualStrings("value2", v2);

        const v3 = (try tr.get("key3", std.testing.allocator)) orelse return error.NotFound;
        defer std.testing.allocator.free(v3);
        try std.testing.expectEqualStrings("value3", v3);

        // Test missing keys
        try std.testing.expect((try tr.get("key0", std.testing.allocator)) == null);
        try std.testing.expect((try tr.get("key4", std.testing.allocator)) == null);
    }
}

test "sstable: bloom filter" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir_path, "bloom.sst" });
    defer std.testing.allocator.free(path);

    // 1. Write SSTable with keys
    {
        var tb = try TableBuilder.create(std.testing.allocator, path, 4096);
        defer tb.deinit();

        try tb.add("apple", "red");
        try tb.add("banana", "yellow");
        try tb.add("cherry", "red");
        try tb.finish();
    }

    // 2. Read and verify
    {
        var tr = try TableReader.open(std.testing.allocator, path);
        defer tr.close();

        // Should have bloom filter
        try std.testing.expect(tr.bloom != null);

        // Existing keys found
        const v1 = (try tr.get("apple", std.testing.allocator)) orelse return error.NotFound;
        defer std.testing.allocator.free(v1);
        try std.testing.expectEqualStrings("red", v1);

        // Missing keys not found
        try std.testing.expect((try tr.get("durian", std.testing.allocator)) == null);
        try std.testing.expect((try tr.get("elderberry", std.testing.allocator)) == null);
    }
}

test "sstable: multi-block read" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir_path, "multi.sst" });
    defer std.testing.allocator.free(path);

    // 1. Write SSTable with small block size to force multiple blocks
    {
        var tb = try TableBuilder.create(std.testing.allocator, path, 100); // Small block size
        defer tb.deinit();

        var buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const key = try std.fmt.bufPrint(&buf, "k{:0>4}", .{i});
            const val = try std.fmt.bufPrint(&buf, "v{:0>4}", .{i});
            try tb.add(key, val);
        }
        try tb.finish();
    }

    // 2. Read random keys
    {
        var tr = try TableReader.open(std.testing.allocator, path);
        defer tr.close();

        // Check first
        const v0 = (try tr.get("k0000", std.testing.allocator)) orelse return error.NotFound;
        defer std.testing.allocator.free(v0);
        try std.testing.expectEqualStrings("v0000", v0);

        // Check last
        const v99 = (try tr.get("k0099", std.testing.allocator)) orelse return error.NotFound;
        defer std.testing.allocator.free(v99);
        try std.testing.expectEqualStrings("v0099", v99);

        // Check middle
        const v50 = (try tr.get("k0050", std.testing.allocator)) orelse return error.NotFound;
        defer std.testing.allocator.free(v50);
        try std.testing.expectEqualStrings("v0050", v50);

        // Check missing
        try std.testing.expect((try tr.get("k0100", std.testing.allocator)) == null);
    }
}

test "sstable: empty table" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir_path, "empty.sst" });
    defer std.testing.allocator.free(path);

    // 1. Write empty SSTable
    {
        var tb = try TableBuilder.create(std.testing.allocator, path, 4096);
        defer tb.deinit();
        try tb.finish();
    }

    // 2. Read
    {
        var tr = try TableReader.open(std.testing.allocator, path);
        defer tr.close();

        try std.testing.expect((try tr.get("anything", std.testing.allocator)) == null);
    }
}

test "sstable: corruption - truncated file" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir_path, "trunc.sst" });
    defer std.testing.allocator.free(path);

    // Create a file smaller than footer (28 bytes)
    {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll("too short");
    }

    // Open should fail
    try std.testing.expectError(error.InvalidSSTable, TableReader.open(std.testing.allocator, path));
}

test "sstable: corruption - truncated index" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir_path, "corrupt_idx.sst" });
    defer std.testing.allocator.free(path);

    // 1. Write valid SSTable
    {
        var tb = try TableBuilder.create(std.testing.allocator, path, 4096);
        defer tb.deinit();
        try tb.add("a", "b");
        try tb.finish();
    }

    // 2. Corrupt the footer: make index_len huge
    {
        const f = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer f.close();
        const st = try f.stat();
        
        // Read footer
        var footer: [28]u8 = undefined;
        try f.preadAll(&footer, st.size - 28);

        // Corrupt index_len (bytes 8..12) to be huge
        std.mem.writeInt(u32, footer[8..12], 0xFFFFFFFF, .little);

        // Write back
        try f.pwriteAll(&footer, st.size - 28);
    }

    // 3. Open should fail (likely EndOfStream when trying to read index)
    try std.testing.expectError(error.EndOfStream, TableReader.open(std.testing.allocator, path));
}

test "sstable: corruption - corrupt bloom header" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir_path, "corrupt_bloom.sst" });
    defer std.testing.allocator.free(path);

    // 1. Write valid SSTable with bloom
    {
        var tb = try TableBuilder.create(std.testing.allocator, path, 4096);
        defer tb.deinit();
        try tb.add("a", "b");
        try tb.finish();
    }

    // 2. Corrupt the footer: make bloom_len small (but > 0) so it fails header check
    {
        const f = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer f.close();
        const st = try f.stat();
        
        // Read footer
        var footer: [28]u8 = undefined;
        try f.preadAll(&footer, st.size - 28);

        // Corrupt bloom_len (bytes 20..24) to be 5 (too small for header)
        std.mem.writeInt(u32, footer[20..24], 5, .little);

        // Write back
        try f.pwriteAll(&footer, st.size - 28);
    }

    // 3. Open should fail
    try std.testing.expectError(error.CorruptBloom, TableReader.open(std.testing.allocator, path));
}

test "sstable: corruption - bad magic" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir_path, "magic.sst" });
    defer std.testing.allocator.free(path);

    // Write a file with enough size but bad magic
    {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        var buf: [28]u8 = undefined;
        @memset(&buf, 0);
        try f.writeAll(&buf);
    }

    try std.testing.expectError(error.InvalidSSTable, TableReader.open(std.testing.allocator, path));
}