const std = @import("std");
const z = @import("ziggydb");
const Block = z.sstable.block;
const Bloom = z.sstable.bloom.Bloom;
const varint = z.codec.varint;

const MAGIC: u32 = 0x5A494742; // "ZIGB"

pub const TableReader = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,
    file_size: u64,
    
    // Cache
    cache: ?*z.cache.lru.LRUCache(BlockCacheKey, []u8) = null,
    file_id: u64 = 0, // Unique ID for cache keys

    // Index block loaded in memory
    index_keys: std.ArrayList([]u8),
    index_offsets: std.ArrayList(u64),
    index_lens: std.ArrayList(u32),

    // Optional Bloom filter
    bloom: ?Bloom = null,

    pub const BlockCacheKey = struct {
        file_id: u64,
        offset: u64,
    };

    pub fn open(allocator: std.mem.Allocator, path: []const u8, cache: ?*z.cache.lru.LRUCache(BlockCacheKey, []u8)) !TableReader {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        errdefer file.close();

        const st = try file.stat();
        const file_size = st.size;
        
        // Generate pseudo-unique file_id from path hash for caching
        const file_id = std.hash.Wyhash.hash(0, path);

        if (file_size < 28) return error.InvalidSSTable;

        // Read footer
        var footer: [28]u8 = undefined;
        try file.preadAll(&footer, file_size - 28);

        const magic = std.mem.readInt(u32, footer[24..28], .little);
        if (magic != MAGIC) return error.InvalidSSTable;

        const index_off = std.mem.readInt(u64, footer[0..8], .little);
        const index_len = std.mem.readInt(u32, footer[8..12], .little);
        const bloom_off = std.mem.readInt(u64, footer[12..20], .little);
        const bloom_len = std.mem.readInt(u32, footer[20..24], .little);

        // Load index block (Always cache index? usually kept in RAM struct anyway)
        const index_data = try allocator.alloc(u8, index_len);
        defer allocator.free(index_data);
        try file.preadAll(index_data, index_off);

        var index_keys = std.ArrayList([]u8).init(allocator);
        errdefer {
            for (index_keys.items) |k| allocator.free(k);
            index_keys.deinit();
        }
        var index_offsets = std.ArrayList(u64).init(allocator);
        errdefer index_offsets.deinit();
        var index_lens = std.ArrayList(u32).init(allocator);
        errdefer index_lens.deinit();

        var off: usize = 0;
        while (off < index_len) {
            const kd = try varint.get(index_data[off..]);
            off += kd.len;
            const klen: usize = @intCast(kd.v);

            if (off + klen + 8 + 4 > index_len) return error.CorruptIndex;

            const key_slice = index_data[off .. off + klen];
            off += klen;

            const block_off = std.mem.readInt(u64, index_data[off .. off + 8], .little);
            off += 8;
            const block_len = std.mem.readInt(u32, index_data[off .. off + 4], .little);
            off += 4;

            const key_copy = try allocator.alloc(u8, klen);
            @memcpy(key_copy, key_slice);
            try index_keys.append(key_copy);
            try index_offsets.append(block_off);
            try index_lens.append(block_len);
        }

        // Load Bloom filter if present
        var bloom: ?Bloom = null;
        if (bloom_len > 0) {
            // Read header: m_bits(4) + k(1) + seed(8) = 13 bytes
            if (bloom_len < 13) return error.CorruptBloom;

            var head: [13]u8 = undefined;
            try file.preadAll(&head, bloom_off);

            const m_bits = std.mem.readInt(u32, head[0..4], .little);
            const k = head[4];
            const seed = std.mem.readInt(u64, head[5..13], .little);

            const bitset_len = bloom_len - 13;
            const bits = try allocator.alloc(u8, bitset_len);
            errdefer allocator.free(bits);
            try file.preadAll(bits, bloom_off + 13);

            bloom = Bloom{
                .m_bits = m_bits,
                .k = k,
                .seed = seed,
                .bits = bits,
            };
        }

        return TableReader{
            .file = file,
            .allocator = allocator,
            .file_size = file_size,
            .cache = cache,
            .file_id = file_id,
            .index_keys = index_keys,
            .index_offsets = index_offsets,
            .index_lens = index_lens,
            .bloom = bloom,
        };
    }

    pub fn close(self: *TableReader) void {
        for (self.index_keys.items) |k| self.allocator.free(k);
        self.index_keys.deinit();
        self.index_offsets.deinit();
        self.index_lens.deinit();
        if (self.bloom) |*b| {
            self.allocator.free(b.bits);
        }
        self.file.close();
    }

    // Helper to read block with cache
    fn readBlock(self: *TableReader, off: u64, len: u32) ![]u8 {
        // 1. Try Cache
        if (self.cache) |c| {
            const key = BlockCacheKey{ .file_id = self.file_id, .offset = off };
            if (c.lookup(key)) |data| {
                return data; // already duped by cache
            }
        }

        // 2. Read from disk
        const buf = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(buf);
        try self.file.preadAll(buf, off);

        // 3. Insert into Cache (if enabled)
        if (self.cache) |c| {
            // cache.insert takes ownership of value. We need to give it a copy 
            // OR give it `buf` and we return a copy?
            // LRUCache insert takes ownership.
            // If we give `buf` to cache, cache owns it.
            // But we need to return a buffer to the caller (Iter/Get) which they will eventually free.
            // So we Make a copy for the cache.
            const cache_copy = try self.allocator.dupe(u8, buf);
            // We use len as charge
            try c.insert(BlockCacheKey{ .file_id = self.file_id, .offset = off }, cache_copy, len);
        }

        return buf;
    }

    pub fn get(self: *TableReader, key: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        // Check Bloom filter first
        if (self.bloom) |*b| {
            if (!b.mayContain(key)) return null;
        }

        const idx = self.lowerBound(key);
        if (idx >= self.index_keys.items.len) return null;

        // Load block via Cache Helper
        const off = self.index_offsets.items[idx];
        const len = self.index_lens.items[idx];

        const block_data = try self.readBlock(off, len);
        defer allocator.free(block_data); // Free the local copy (cache has its own)

        var iter = Block.BlockIter.init(block_data);
        while (try iter.next()) |entry| {
            const ord = std.mem.order(u8, entry.key, key);
            if (ord == .eq) {
                const v = try allocator.alloc(u8, entry.value.len);
                @memcpy(v, entry.value);
                return v;
            }
            if (ord == .gt) {
                return null;
            }
        }

        return null;
    }

    // Iterator over the SSTable
    pub const Iter = struct {
        tr: *TableReader,
        block_idx: usize,
        block_iter: ?Block.BlockIter = null,
        
        // Boundaries
        end_key: []const u8,
        
        current_block_buf: []u8 = &[_]u8{},

        pub fn init(tr: *TableReader, start_key: []const u8, end_key: []const u8) !Iter {
            var it = Iter{
                .tr = tr,
                .block_idx = 0,
                .end_key = end_key,
            };

            if (start_key.len > 0) {
                it.block_idx = tr.lowerBound(start_key);
            }
            
            if (it.block_idx < tr.index_keys.items.len) {
                try it.loadBlock();
                if (start_key.len > 0) {
                   while (try it.peek()) |k| {
                       if (std.mem.order(u8, k, start_key) != .lt) break;
                       _ = try it.next();
                   }
                }
            }
            
            return it;
        }
        
        pub fn deinit(self: *Iter) void {
             if (self.current_block_buf.len > 0) {
                 self.tr.allocator.free(self.current_block_buf);
             }
        }
        
        fn loadBlock(self: *Iter) !void {
            if (self.current_block_buf.len > 0) {
                self.tr.allocator.free(self.current_block_buf);
                self.current_block_buf = &[_]u8{};
            }
            
            if (self.block_idx >= self.tr.index_keys.items.len) {
                self.block_iter = null;
                return;
            }

            const off = self.tr.index_offsets.items[self.block_idx];
            const len = self.tr.index_lens.items[self.block_idx];
            
            // Use readBlock from TR (cached)
            const buf = try self.tr.readBlock(off, len);
            self.current_block_buf = buf;
            
            self.block_iter = Block.BlockIter.init(buf);
        }

        pub fn next(self: *Iter) !?struct { key: []const u8, value: []const u8 } {
            while (true) {
                if (self.block_iter) |*bi| {
                    if (try bi.next()) |entry| {
                        if (self.end_key.len > 0 and std.mem.order(u8, entry.key, self.end_key) != .lt) {
                            return null;
                        }
                        return entry;
                    }
                    self.block_idx += 1;
                    try self.loadBlock();
                } else {
                    return null;
                }
            }
        }
        
        pub fn peek(self: *Iter) !?[]const u8 {
            while (true) {
                if (self.block_iter) |*bi| {
                    if (try bi.peek()) |k| {
                        if (self.end_key.len > 0 and std.mem.order(u8, k, self.end_key) != .lt) {
                            return null;
                        }
                        return k;
                    }
                    self.block_idx += 1;
                    try self.loadBlock();
                } else {
                    return null;
                }
            }
        }
    };

    fn lowerBound(self: *TableReader, key: []const u8) usize {
        var left: usize = 0;
        var right: usize = self.index_keys.items.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (std.mem.order(u8, self.index_keys.items[mid], key) == .lt) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return left;
    }
};