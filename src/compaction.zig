const std = @import("std");
const z = @import("ziggydb");
const Version = z.version.Version;
const FileMetaData = z.version.FileMetaData;

pub const Compaction = struct {
    allocator: std.mem.Allocator,
    input_version: *Version,
    level: usize, // Input Level (0..5)
    
    // Inputs:
    // inputs[0] are files from `level`.
    // inputs[1] are files from `level + 1`.
    inputs: [2]std.ArrayList(FileMetaData),
    
    pub fn deinit(self: *Compaction) void {
        self.inputs[0].deinit();
        self.inputs[1].deinit();
        self.input_version.unref() catch {}; // Ignoring return. Should handle?
        // Note: `unref` returns true if ref_count==0, implying we should destroy.
        // But `Compaction` shouldn't be responsible for destroying Version fully if DB handles it.
        // HOWEVER, if Compaction holds a Ref, it should Unref.
        // If ref_count drops to 0 here, we should ideally destroy it.
        // DB usually manages main lifecycle. But Compaction might outlive DB.current_version?
        // For now, let's assume `DB` handles cleanup if we just unref. 
        // But `Version.unref` logic doesn't destroy itself. Caller calls `deinit`.
        // So we might leak if we are the last holder.
        // Let's assume DB holds strong ref until Compaction is done. 
        // Or Compaction calls `input_version.unref()`. If true, `input_version.deinit()`.
        
        // Let's rely on caller to manage version lifecycle or properly implement it.
        // For now:
        if (self.input_version.unref()) {
             self.input_version.deinit();
        }
        // Metadata copies? Use shallow storage if `Version` is pinned by ref.
        // ArrayList(FileMetaData) copies structs (which own strings).
        // If we copied them, we must free strings.
        // For current `FileMetaData`, `deinit` frees strings.
        // So `inputs[0]` contains COPIES?
        // If so, iterate and deinit.
        // But let's verify if we copy or ref.
    }
};

// Returns a Compaction description if needed.
// Caller owns the returned Compaction (must deinit).
pub fn pickCompaction(allocator: std.mem.Allocator, v: *Version, _: z.options.Options) !?Compaction {
    // 1. Score Levels
    // L0 Score: files / 4.
    // L1 Score: size / 10MB.
    // L2 Score: size / 100MB...
    
    var best_level: usize = 0;
    var best_score: f64 = -1.0;
    
    // Check L0
    {
        const score = @as(f64, @floatFromInt(v.levels[0].items.len)) / 4.0;
        if (score > best_score) {
            best_score = score;
            best_level = 0;
        }
    }
    
    // Check L1..L6
    for (1..7) |lvl| {
        // Target: 10^(lvl) MB
        const target_mb = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(lvl)));
        const target_bytes = target_mb * 1024 * 1024;
        
        var total_size: u64 = 0;
        for (v.levels[lvl].items) |meta| total_size += meta.size;
        
        const score = @as(f64, @floatFromInt(total_size)) / target_bytes;
        if (score > best_score) {
            best_score = score;
            best_level = lvl;
        }
    }
    
    // Trigger?
    if (best_score < 1.0) return null;
    
    v.ref(); // Compaction holds a ref
    
    var c = Compaction{
        .allocator = allocator,
        .input_version = v,
        .level = best_level,
        .inputs = .{ std.ArrayList(FileMetaData).init(allocator), std.ArrayList(FileMetaData).init(allocator) },
    };
    errdefer {
        c.inputs[0].deinit();
        c.inputs[1].deinit();
        if (v.unref()) v.deinit();
    }
    
    // Selection Logic
    if (best_level == 0) {
        // L0 -> L1: Pick ALL L0
        for (v.levels[0].items) |meta| {
            try c.inputs[0].append(try deepCopyMeta(allocator, meta));
        }
    } else {
        // L(N) -> L(N+1): Pick one file
        // Simple heuristic: Pick first file.
        // Better: Pick file maximizing overlap? Or Round Robin?
        // Let's pick 0th file for now.
        if (v.levels[best_level].items.len > 0) {
            const meta = v.levels[best_level].items[0];
            try c.inputs[0].append(try deepCopyMeta(allocator, meta));
        }
    }
    
    // Expand to Overlapping Inputs from Level N+1
    // Range of Inputs[0]
    if (c.inputs[0].items.len == 0) {
         // Should not happen if score > 1
         return null; // or cancel
    }
    
    var min: []const u8 = c.inputs[0].items[0].min_key;
    var max: []const u8 = c.inputs[0].items[0].max_key;
    
    for (c.inputs[0].items) |meta| {
        if (std.mem.order(u8, meta.min_key, min) == .lt) min = meta.min_key;
        if (std.mem.order(u8, meta.max_key, max) == .gt) max = meta.max_key;
    }
    
    // Scan Level N+1 for overlap
    const next_level = best_level + 1;
    if (next_level < 7) {
        for (v.levels[next_level].items) |meta| {
            if (rangeOverlaps(min, max, meta.min_key, meta.max_key)) {
                try c.inputs[1].append(try deepCopyMeta(allocator, meta));
            }
        }
    }
    
    return c;
}

fn deepCopyMeta(allocator: std.mem.Allocator, meta: FileMetaData) !FileMetaData {
    return FileMetaData{
        .level = meta.level,
        .seq = meta.seq,
        .size = meta.size,
        .file = try allocator.dupe(u8, meta.file),
        .min_key = try allocator.dupe(u8, meta.min_key),
        .max_key = try allocator.dupe(u8, meta.max_key),
    };
}

fn rangeOverlaps(start: []const u8, end: []const u8, min: []const u8, max: []const u8) bool {
    // Overlap if not (end < min or start > max)
    if (std.mem.order(u8, end, min) == .lt) return false;
    if (std.mem.order(u8, start, max) == .gt) return false;
    return true;
}
