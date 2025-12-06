const std = @import("std");

pub const FileMetaData = struct {
    level: u8,
    file: []u8, // Owned
    size: u64, // File size in bytes
    seq: u64,
    min_key: []u8, // Owned (if we copy it, usually duplicate from manifest?)
    max_key: []u8, // Owned

    pub fn deinit(self: FileMetaData, allocator: std.mem.Allocator) void {
         allocator.free(self.file);
         // min_key/max_key might be owned? 
         // In simplified V1, we didn't store min/max in Version, only in Manifest Entry.
         // But for Leveled Compaction, we need min/max to check overlap.
         // So we should store them.
         // For now, let's keep it simple: store copies.
         allocator.free(self.min_key);
         allocator.free(self.max_key);
    }
};

pub const Version = struct {
    allocator: std.mem.Allocator,
    // levels[0] ... levels[6]
    levels: [7]std.ArrayList(FileMetaData),
    
    ref_count: std.atomic.Value(usize),
    
    next: ?*Version = null,
    prev: ?*Version = null,

    pub fn init(allocator: std.mem.Allocator) !*Version {
        const v = try allocator.create(Version);
        var levels: [7]std.ArrayList(FileMetaData) = undefined;
        for (0..7) |i| {
            levels[i] = std.ArrayList(FileMetaData).init(allocator);
        }
        
        v.* = .{
            .allocator = allocator,
            .levels = levels,
            .ref_count = std.atomic.Value(usize).init(1),
        };
        return v;
    }

    pub fn ref(self: *Version) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn unref(self: *Version) bool {
        const prev_rc = self.ref_count.fetchSub(1, .release);
        if (prev_rc == 1) {
            self.ref_count.fence(.acquire);
            return true;
        }
        return false;
    }

    pub fn deinit(self: *Version) void {
        for (self.levels) |*lvl| {
            for (lvl.items) |meta| {
                meta.deinit(self.allocator);
            }
            lvl.deinit();
        }
        self.allocator.destroy(self);
    }
    
    // Legacy helper (for tests/compatibility that used flat files)
    // NOTE: This will be removed. Code using `v.files` MUST migrate.
    // For now, removing `files` field breaks compilation.
    // I will NOT provide `files`. I'll let compilation fail so I find all call sites.
};
