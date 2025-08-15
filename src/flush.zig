const std = @import("std");
const z = @import("ziggydb");

pub const FlushResult = struct {
    seq: u64,
    file_path: []u8,
    min_key: []u8,
    max_key: []u8,
};

pub fn flushMemtableToSST(
    allocator: std.mem.Allocator,
    dir: []const u8,
    seq: u64,
    mt: *z.memtable.MemTable,
    read_ts: u64,
    block_size: usize,
) !FlushResult {
    try z.util.fs.ensureDir(dir);

    var namebuf: [64]u8 = undefined;
    const fname = sstName(&namebuf, seq);
    const path = try std.fs.path.join(allocator, &.{ dir, fname });
    errdefer allocator.free(path);

    var tb = try z.sstable.builder.TableBuilder.create(allocator, path, block_size);
    defer tb.deinit();

    var it = z.memtable.MemTable.Iter.init(mt, read_ts, &[_]u8{}, &[_]u8{});
    var min_key: []u8 = &.{};
    var max_key: []u8 = &.{};
    var have = false;

    while (it.next()) |e| {
        if (!have) {
            min_key = try dup(allocator, e.user_key);
            have = true;
        }
        max_key = try setOrReplace(allocator, max_key, e.user_key);
        try tb.add(e.user_key, e.value);
    }
    try tb.finish();

    if (!have) {
        min_key = try dup(allocator, "");
        max_key = try dup(allocator, "");
    }

    return .{
        .seq = seq,
        .file_path = path,
        .min_key = min_key,
        .max_key = max_key,
    };
}

fn dup(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try a.alloc(u8, s.len);
    @memcpy(out, s);
    return out;
}

fn setOrReplace(a: std.mem.Allocator, old: []u8, s: []const u8) ![]u8 {
    if (old.len != 0) a.free(old);
    return dup(a, s);
}

fn sstName(buf: []u8, seq: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{:0>6}.sst", .{seq}) catch unreachable;
}

test "flush: memtable → sst" {
    const std_local = @import("std");
    const z_local = @import("ziggydb");

    var gpa = std_local.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const tmp = std_local.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = try z_local.util.arena.Arena.init(gpa.allocator(), 64 * 1024);
    defer arena.deinit();

    var mt = try z_local.memtable.MemTable.init(&arena);
    try mt.put(1, "a", "A");
    try mt.put(2, "b", "B");
    try mt.put(3, "c", "C");

    const fr = try flushMemtableToSST(gpa.allocator(), tmp.dir_path, 1, &mt, std_local.math.maxInt(u64), 4096);
    defer {
        gpa.allocator().free(fr.file_path);
        gpa.allocator().free(fr.min_key);
        gpa.allocator().free(fr.max_key);
    }
    try std_local.testing.expect(std_local.mem.eql(u8, fr.min_key, "a"));
    try std_local.testing.expect(std_local.mem.eql(u8, fr.max_key, "c"));

    // sanity read
    var tr = try z_local.sstable.reader.TableReader.open(gpa.allocator(), fr.file_path);
    defer tr.close();
    const v = (try tr.get("b", gpa.allocator())) orelse return error.Miss;
    defer gpa.allocator().free(v);
    try std_local.testing.expectEqualStrings("B", v);
}