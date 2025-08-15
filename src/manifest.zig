const std = @import("std");

pub const Entry = struct {
    seq: u64,
    file: []const u8,
    min_key: []const u8,
    max_key: []const u8,
};

pub const Manifest = struct {
    entries: []Entry,
    slab: []u8,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, dir: []const u8) !Manifest {
        const path = try std.fs.path.join(allocator, &.{ dir, "MANIFEST" });
        defer allocator.free(path);

        var file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |e| switch (e) {
            error.FileNotFound => return .{ .entries = &.{}, .slab = &.{}, .allocator = allocator },
            else => return e,
        };
        defer file.close();

        const st = try file.stat();
        const slab = try allocator.alloc(u8, st.size);
        errdefer allocator.free(slab);
        try file.readAll(slab);

        var it = std.mem.splitScalar(u8, slab, '\n');
        if (it.next()) |hdr| {
            if (!std.mem.eql(u8, hdr, "ZIGGYDB MANIFEST v1")) return error.BadManifest;
        } else return error.BadManifest;

        var entries = std.ArrayList(Entry).init(allocator);

        while (it.next()) |line| {
            if (line.len == 0) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            const seqs = cols.next() orelse return error.BadManifest;
            const files = cols.next() orelse return error.BadManifest;
            const mins = cols.next() orelse return error.BadManifest;
            const maxs = cols.next() orelse return error.BadManifest;

            const seq = std.fmt.parseInt(u64, seqs, 10) catch return error.BadManifest;

            try entries.append(.{
                .seq = seq,
                .file = sliceFromSlab(slab, files),
                .min_key = sliceFromSlab(slab, mins),
                .max_key = sliceFromSlab(slab, maxs),
            });
        }

        return .{
            .entries = try entries.toOwnedSlice(),
            .slab = slab,
            .allocator = allocator,
        };
    }

    fn sliceFromSlab(slab: []u8, s: []const u8) []const u8 {
        const slab_start = @intFromPtr(slab.ptr);
        const s_start    = @intFromPtr(s.ptr);
        const base: usize = s_start - slab_start;           // result is usize
        std.debug.assert(base + s.len <= slab.len);         // safety
        return slab[base .. base + s.len];                  // no casts needed
    }

    pub fn close(self: *Manifest) void {
        if (self.entries.len != 0) self.allocator.free(self.entries);
        if (self.slab.len != 0) self.allocator.free(self.slab);
        self.* = .{ .entries = &.{}, .slab = &.{}, .allocator = self.allocator };
    }

    pub fn append(self: *Manifest, dir: []const u8, e: Entry) !void {
        const path = try std.fs.path.join(self.allocator, &.{ dir, "MANIFEST" });
        defer self.allocator.free(path);

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.writer().print("{s}\n", .{"ZIGGYDB MANIFEST v1"});
        for (self.entries) |old| {
            try buf.writer().print("{d}\t{s}\t{s}\t{s}\n", .{ old.seq, old.file, old.min_key, old.max_key });
        }
        try buf.writer().print("{d}\t{s}\t{s}\t{s}\n", .{ e.seq, e.file, e.min_key, e.max_key });

        const tmp = try std.fmt.allocPrint(self.allocator, "{s}/MANIFEST.tmp", .{dir});
        defer self.allocator.free(tmp);
        {
            var f = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
            defer f.close();
            try f.writeAll(buf.items);
            try f.sync();
        }
        try std.fs.cwd().rename(tmp, path);
    }
};

test "manifest open/append roundtrip" {
    const std_local = @import("std");
    const tmp = std_local.testing.tmpDir(.{});
    defer tmp.cleanup();

    var m = try Manifest.open(std_local.heap.page_allocator, tmp.dir_path);
    defer m.close();

    try m.append(tmp.dir_path, .{ .seq = 1, .file = "000001.sst", .min_key = "a", .max_key = "m" });
    try m.append(tmp.dir_path, .{ .seq = 2, .file = "000002.sst", .min_key = "n", .max_key = "z" });

    m.close();

    var m2 = try Manifest.open(std_local.heap.page_allocator, tmp.dir_path);
    defer m2.close();

    try std_local.testing.expectEqual(@as(usize, 2), m2.entries.len);
    try std_local.testing.expect(std_local.mem.eql(u8, m2.entries[1].file, "000002.sst"));
}