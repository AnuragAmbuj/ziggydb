const std = @import("std");
const z = @import("ziggydb");
const Block  = z.sstable.block;
const varint = z.codec.varint;

const MAGIC: u32 = 0x5A494742; // "ZIGB" (with bloom)

pub const TableBuilder = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,
    block_size: usize,
    block: Block.BlockBuilder,
    index_keys: std.ArrayList([]const u8),
    index_meta: std.ArrayList(struct { off: u64, len: u32 }),
    start_off: u64,

    // NEW: collect key hashes for bloom
    key_hashes: std.ArrayList(u64),

    pub fn create(allocator: std.mem.Allocator, path: []const u8, block_size: usize) !TableBuilder {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = true });
        const st = try file.stat();
        return .{
            .file = file,
            .allocator = allocator,
            .block_size = std.math.max(block_size, 4096),
            .block = Block.BlockBuilder.init(allocator),
            .index_keys = std.ArrayList([]const u8).init(allocator),
            .index_meta = std.ArrayList(struct { off: u64, len: u32 }).init(allocator),
            .start_off = @intCast(st.size),
            .key_hashes = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *TableBuilder) void {
        self.block.deinit();
        for (self.index_keys.items) |k| self.allocator.free(k);
        self.index_keys.deinit();
        self.index_meta.deinit();
        self.key_hashes.deinit();
        self.file.close();
    }

    fn dup(self: *TableBuilder, s: []const u8) ![]u8 {
        const out = try self.allocator.alloc(u8, s.len);
        @memcpy(out, s);
        return out;
    }

    fn flushBlock(self: *TableBuilder) !void {
        if (self.block.isEmpty()) return;
        const st = try self.file.stat();
        const off: u64 = @intCast(st.size);

        try self.file.writeAll(self.block.bytes());

        const key_copy = try self.dup(self.block.last_key);
        try self.index_keys.append(key_copy);
        try self.index_meta.append(.{ .off = off, .len = @intCast(self.block.len()) });

        self.block.deinit();
        self.block = Block.BlockBuilder.init(self.allocator);
    }

    pub fn add(self: *TableBuilder, key: []const u8, value: []const u8) !void {
        if (!self.block.isEmpty() and self.block.len() + key.len + value.len + 20 > self.block_size) {
            try self.flushBlock();
        }
        try self.block.add(key, value);

        // collect hash for bloom
        try self.key_hashes.append(fnv1a64(key));
    }

    pub fn finish(self: *TableBuilder) !void {
        try self.flushBlock();

        // write index block
        const index_off = (try self.file.stat()).size;
        var i: usize = 0;
        while (i < self.index_keys.items.len) : (i += 1) {
            const k = self.index_keys.items[i];
            var tmp: [10]u8 = undefined;
            const nk = varint.put(&tmp, k.len);
            try self.file.writeAll(tmp[0..nk]);
            try self.file.writeAll(k);

            var offb: [8]u8 = undefined;
            std.mem.writeInt(u64, offb[0..8], self.index_meta.items[i].off, .little);
            try self.file.writeAll(offb[0..8]);

            var lenb: [4]u8 = undefined;
            std.mem.writeInt(u32, lenb[0..4], self.index_meta.items[i].len, .little);
            try self.file.writeAll(lenb[0..4]);
        }
        const index_len: u32 = @intCast(((try self.file.stat()).size - index_off));

        // NEW: build and write bloom block (optional if no keys)
        var bloom_off: u64 = 0;
        var bloom_len: u32 = 0;
        if (self.key_hashes.items.len != 0) {
            bloom_off = (try self.file.stat()).size;

            var bloom = try z.sstable.bloom.Bloom.init(self.allocator, self.key_hashes.items.len, 0.01, 0xB100B100B100B100);
            defer bloom.deinit(self.allocator);

            // Re-hash keys by feeding their 64-bit hash bytes; or re-hash original keys during add().
            // We stored 64-bit digests; feed them as bytes for stable behavior.
            var hb: [8]u8 = undefined;
            var j: usize = 0;
            while (j < self.key_hashes.items.len) : (j += 1) {
                std.mem.writeInt(u64, hb[0..8], self.key_hashes.items[j], .little);
                bloom.add(hb[0..8]);
            }

            // write bloom header
            var head: [4 + 1 + 8]u8 = undefined;
            std.mem.writeInt(u32, head[0..4], bloom.m_bits, .little);
            head[4] = bloom.k;
            std.mem.writeInt(u64, head[5..13], bloom.seed, .little);
            try self.file.writeAll(head[0..13]);

            // write bitset
            try self.file.writeAll(bloom.bits);

            bloom_len = @intCast(((try self.file.stat()).size - bloom_off));
        }

        // footer (with bloom)
        var fb: [8 + 4 + 8 + 4 + 4]u8 = undefined;
        std.mem.writeInt(u64, fb[0..8], @intCast(index_off), .little);
        std.mem.writeInt(u32, fb[8..12], index_len, .little);
        std.mem.writeInt(u64, fb[12..20], bloom_off, .little);
        std.mem.writeInt(u32, fb[20..24], bloom_len, .little);
        std.mem.writeInt(u32, fb[24..28], MAGIC, .little);
        try self.file.writeAll(fb[0..28]);

        try self.file.sync();
    }
};

// simple 64-bit FNV-1a for key hashing in-memory
fn fnv1a64(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const prime: u64 = 0x100000001b3;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        h ^= data[i];
        h *%= prime;
    }
    return h;
}