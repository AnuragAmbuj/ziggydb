const std = @import("std");
const z = @import("ziggydb");
const varint = z.codec.varint;
const Block = z.sstable.block;

const MAGIC: u32 = 0x5A494747;

pub const TableReader = struct {
    file: std.fs.File,
    // parsed index in memory
    keys: [][]const u8,
    offs: []u64,
    lens: []u32,
    slab: []u8,                 // backing for keys
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !TableReader {
        var f = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        const st = try f.stat();
        if (st.size < 16) return error.Corrupted;

        // read footer
        var fb: [16]u8 = undefined;
        try f.preadAll(&fb, st.size - 16);
        const magic = std.mem.readInt(u32, fb[12..16], .little);
        if (magic != MAGIC) return error.BadMagic;
        const index_off = std.mem.readInt(u64, fb[0..8], .little);
        const index_len = std.mem.readInt(u32, fb[8..12], .little);
        if (index_off + index_len > st.size - 16) return error.Corrupted;

        // read entire index
        var slab = try allocator.alloc(u8, index_len);
        errdefer allocator.free(slab);
        try f.preadAll(slab, index_off);

        // parse index into arrays (point into slab)
        var keys = std.ArrayList([]const u8).init(allocator);
        var offs = std.ArrayList(u64).init(allocator);
        var lens = std.ArrayList(u32).init(allocator);

        var off: usize = 0;
        while (off < slab.len) {
            // key len
            const kd = try varint.get(slab[off..]);
            off += kd.len;
            const klen: usize = @intCast(kd.v);
            if (off + klen + 8 + 4 > slab.len) break;
            const key = slab[off .. off + klen];
            off += klen;

            const boff = std.mem.readInt(u64, slab[off .. off + 8], .little);
            off += 8;
            const blen = std.mem.readInt(u32, slab[off .. off + 4], .little);
            off += 4;

            try keys.append(key);
            try offs.append(boff);
            try lens.append(blen);
        }

        return .{
            .file = f,
            .keys = try keys.toOwnedSlice(),
            .offs = try offs.toOwnedSlice(),
            .lens = try lens.toOwnedSlice(),
            .slab = slab,
            .allocator = allocator,
        };
    }

    pub fn close(self: *TableReader) void {
        self.file.close();
        self.allocator.free(self.keys);
        self.allocator.free(self.offs);
        self.allocator.free(self.lens);
        self.allocator.free(self.slab);
    }

    // Binary search the index for the first block whose last_key >= key
    fn findBlock(self: *TableReader, key: []const u8) ?usize {
        var lo: usize = 0;
        var hi: usize = self.keys.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const ord = std.mem.order(u8, self.keys[mid], key);
            if (ord == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo >= self.keys.len) return null;
        return lo;
    }

    pub fn get(self: *TableReader, key: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        const bi = self.findBlock(key) orelse return null;

        // read block bytes
        const off = self.offs[bi];
        const len = self.lens[bi];
        const buf = try allocator.alloc(u8, len);
        errdefer allocator.free(buf);
        try self.file.preadAll(buf, off);

        var it = Block.BlockIter.init(buf);
        while (try it.next()) |e| {
            const ord = std.mem.order(u8, e.key, key);
            if (ord == .eq) {
                const out = try allocator.alloc(u8, e.value.len);
                @memcpy(out, e.value);
                allocator.free(buf);
                return out;
            }
            if (ord == .gt) break;
        }
        allocator.free(buf);
        return null;
    }

    pub const Iter = struct {
        tr: *TableReader,
        block_idx: usize,
        block_buf: []u8 = &[_]u8{},
        it: Block.BlockIter = undefined,
        end: []const u8,
        allocator: std.mem.Allocator,
        started: bool = false,

        pub fn init(tr: *TableReader, allocator: std.mem.Allocator, start: []const u8, end: []const u8) !Iter {
            var block_idx: usize = 0;
            if (start.len != 0) {
                if (tr.findBlock(start)) |i| block_idx = i;
            }
            var iter = Iter{
                .tr = tr,
                .block_idx = block_idx,
                .end = end,
                .allocator = allocator,
            };
            try iter.loadBlock();
            return iter;
        }

        fn loadBlock(self: *Iter) !void {
            if (self.block_idx >= self.tr.keys.len) {
                self.block_buf = &[_]u8{};
                return;
            }
            const off = self.tr.offs[self.block_idx];
            const len = self.tr.lens[self.block_idx];
            if (self.block_buf.len != 0) self.allocator.free(self.block_buf);
            self.block_buf = try self.allocator.alloc(u8, len);
            try self.tr.file.preadAll(self.block_buf, off);
            self.it = Block.BlockIter.init(self.block_buf);
        }

        pub fn deinit(self: *Iter) void {
            if (self.block_buf.len != 0) self.allocator.free(self.block_buf);
        }

        pub fn next(self: *Iter) !?struct { key: []const u8, value: []const u8 } {
            while (true) {
                if (self.block_idx >= self.tr.keys.len) return null;
                if (try self.it.next()) |e| {
                    if (self.end.len != 0 and std.mem.order(u8, e.key, self.end) != .lt) return null;
                    return e;
                } else {
                    self.block_idx += 1;
                    try self.loadBlock();
                }
            }
        }
    };
};