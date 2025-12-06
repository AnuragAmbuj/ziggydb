const std = @import("std");

pub const Entry = struct {
    level: u8 = 0, // NEW field
    seq: u64,
    file: []const u8,
    min_key: []const u8,
    max_key: []const u8,
};

pub const VersionEdit = struct {
    new_files: []const Entry = &.{},
    deleted_files: []const []const u8 = &.{},
    log_number: ?u64 = null,
};

pub const Manifest = struct {
    entries: []Entry,
    log_number: u64,
    slab: []u8,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, dir: []const u8) !Manifest {
        const path = try std.fs.path.join(allocator, &.{ dir, "MANIFEST" });
        defer allocator.free(path);

        var file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |e| switch (e) {
            error.FileNotFound => return .{ .entries = &.{}, .log_number = 0, .slab = &.{}, .allocator = allocator },
            else => return e,
        };
        defer file.close();

        const st = try file.stat();
        const slab = try allocator.alloc(u8, st.size);
        errdefer allocator.free(slab);
        try file.readAll(slab);

        var it = std.mem.splitScalar(u8, slab, '\n');
        // Handle both older v2 (flat) and new v3 (leveled)?
        // For now, strict v3 check. Or maybe reuse "ZIGGYDB MANIFEST v2" but change line format?
        // Let's adhere to "ZIGGYDB MANIFEST v3"
        // But the previous file content was "v2".
        // To avoid complexity, we can bump version to v3.
        const header = it.next();
        var is_v3 = false;
        
        if (header) |hdr| {
             if (std.mem.eql(u8, hdr, "ZIGGYDB MANIFEST v3")) {
                 is_v3 = true;
             } else if (std.mem.eql(u8, hdr, "ZIGGYDB MANIFEST v2")) {
                 is_v3 = false;
             } else {
                 // return error.BadManifest; // Or treat empty/unknown?
                 // Wait, new DB might not exist.
             }
        } else {
            // empty file?
            return error.BadManifest;
        }

        var entries_map = std.StringHashMap(Entry).init(allocator);
        defer entries_map.deinit();
        
        var current_log: u64 = 0;

        while (it.next()) |line| {
            if (line.len == 0) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            const op = cols.next() orelse return error.BadManifest;
            
            if (std.mem.eql(u8, op, "+")) {
                if (is_v3) {
                    // + level seq file min max
                    const level_s = cols.next() orelse return error.BadManifest;
                    const seqs = cols.next() orelse return error.BadManifest;
                    const files = cols.next() orelse return error.BadManifest;
                    const mins = cols.next() orelse return error.BadManifest;
                    const maxs = cols.next() orelse return error.BadManifest;

                    const level = std.fmt.parseInt(u8, level_s, 10) catch return error.BadManifest;
                    const seq = std.fmt.parseInt(u64, seqs, 10) catch return error.BadManifest;
                    const file_name = sliceFromSlab(slab, files);
                    
                    try entries_map.put(file_name, .{
                        .level = level,
                        .seq = seq,
                        .file = file_name,
                        .min_key = sliceFromSlab(slab, mins),
                        .max_key = sliceFromSlab(slab, maxs),
                    });
                } else {
                    // v2: + seq file min max (assume L0)
                    const seqs = cols.next() orelse return error.BadManifest;
                    const files = cols.next() orelse return error.BadManifest;
                    const mins = cols.next() orelse return error.BadManifest;
                    const maxs = cols.next() orelse return error.BadManifest;

                    const seq = std.fmt.parseInt(u64, seqs, 10) catch return error.BadManifest;
                    const file_name = sliceFromSlab(slab, files);
                    
                    try entries_map.put(file_name, .{
                        .level = 0,
                        .seq = seq,
                        .file = file_name,
                        .min_key = sliceFromSlab(slab, mins),
                        .max_key = sliceFromSlab(slab, maxs),
                    });
                }

            } else if (std.mem.eql(u8, op, "-")) {
                 const files = cols.next() orelse return error.BadManifest;
                 _ = entries_map.remove(files);
            } else if (std.mem.eql(u8, op, "LOG")) {
                 const log_s = cols.next() orelse return error.BadManifest;
                 current_log = std.fmt.parseInt(u64, log_s, 10) catch return error.BadManifest;
            } else {
                return error.BadManifest;
            }
        }
        
        // Convert map to list
        var entries = std.ArrayList(Entry).init(allocator);
        var val_it = entries_map.valueIterator();
        while (val_it.next()) |v| {
            try entries.append(v.*);
        }

        std.mem.sort(Entry, entries.items, {}, struct{
            fn less(_: void, a: Entry, b: Entry) bool { 
                // Sort by Level primarily, then Sequence?
                // Or just Sequence?
                // For recovery, sequence matters for L0.
                if (a.level != b.level) return a.level < b.level;
                return a.seq < b.seq; 
            } 
        }.less);

        return .{
            .entries = try entries.toOwnedSlice(),
            .log_number = current_log,
            .slab = slab,
            .allocator = allocator,
        };
    }

    fn sliceFromSlab(slab: []u8, s: []const u8) []const u8 {
        const slab_start = @intFromPtr(slab.ptr);
        const s_start    = @intFromPtr(s.ptr);
        const base: usize = s_start - slab_start;
        std.debug.assert(base + s.len <= slab.len);
        return slab[base .. base + s.len];
    }

    pub fn close(self: *Manifest) void {
        if (self.entries.len != 0) self.allocator.free(self.entries);
        if (self.slab.len != 0) self.allocator.free(self.slab);
        self.* = .{ .entries = &.{}, .log_number = 0, .slab = &.{}, .allocator = self.allocator };
    }

    pub fn log(self: *Manifest, dir: []const u8, edit: VersionEdit) !void {
        const path = try std.fs.path.join(self.allocator, &.{ dir, "MANIFEST" });
        defer self.allocator.free(path);

        const file_exists = blk: {
            std.fs.cwd().access(path, .{}) catch |e| switch (e) {
                error.FileNotFound => break :blk false,
                else => return e,
            };
            break :blk true;
        };
        
        var f = if (file_exists) 
            try std.fs.cwd().openFile(path, .{ .mode = .read_write }) 
        else 
            try std.fs.cwd().createFile(path, .{});
        defer f.close();
        
        const stat = try f.stat();
        try f.seekTo(stat.size);
        
        const w = f.writer();
        if (stat.size == 0) {
             // Upgrade to v3
             try w.print("{s}\n", .{"ZIGGYDB MANIFEST v3"});
        }
           
        for (edit.deleted_files) |d| {
            try w.print("-\t{s}\n", .{d});
        }
        for (edit.new_files) |e| {
            // + level seq file min max
            try w.print("+\t{d}\t{d}\t{s}\t{s}\t{s}\n", .{ e.level, e.seq, e.file, e.min_key, e.max_key });
        }
        if (edit.log_number) |ln| {
            try w.print("LOG\t{d}\n", .{ln});
        }
        try f.sync();
    }
};

test "manifest v3 roundtrip" {
    const std_local = @import("std");
    const tmp = std_local.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 1. Create and log edits
    {
        var m = Manifest{ .entries = &.{}, .slab = &.{}, .allocator = std_local.testing.allocator };
        
        // Add files to L0 and L1
        try m.log(tmp.dir_path, .{
            .new_files = &.{
                .{ .level = 0, .seq = 5, .file = "f1.sst", .min_key = "a", .max_key = "z" },
                .{ .level = 1, .seq = 2, .file = "f2.sst", .min_key = "0", .max_key = "9" },
            }
        });
        
        // Delete f1, Add f3 to L2
        try m.log(tmp.dir_path, .{
            .deleted_files = &.{ "f1.sst" },
            .new_files = &.{
                .{ .level = 2, .seq = 3, .file = "f3.sst", .min_key = "b", .max_key = "y" },
            }
        });
    }

    // 2. Open and verify state
    {
        var m = try Manifest.open(std_local.testing.allocator, tmp.dir_path);
        defer m.close();
        
        try std_local.testing.expectEqual(@as(usize, 2), m.entries.len);
        
        // Sorted by Level (Level 1 < Level 2).
        // f2 is L1. f3 is L2.
        try std_local.testing.expect(std_local.mem.eql(u8, m.entries[0].file, "f2.sst"));
        try std_local.testing.expectEqual(@as(u8, 1), m.entries[0].level);
        
        try std_local.testing.expect(std_local.mem.eql(u8, m.entries[1].file, "f3.sst"));
        try std_local.testing.expectEqual(@as(u8, 2), m.entries[1].level);
    }
}