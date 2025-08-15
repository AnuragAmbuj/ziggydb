const z = @import("ziggydb");
const std = @import("std");
const fsu = z.util.fs;
const crc32c = z.codec.crc32c;

pub const RecordType = enum(u8) {
    Batch = 1,
};

pub const Writer = struct {
    dir_path: []const u8,
    seg_max_bytes: usize,
    file: ?std.fs.File = null,
    written_in_seg: usize = 0,
    next_seq: u64 = 1, // segment sequence (1-based)
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, dir_path: []const u8, seg_max_bytes: usize) !Writer {
        try fsu.ensureDir(dir_path);
        var w = Writer{
            .dir_path = try dup(allocator, dir_path),
            .seg_max_bytes = std.math.max(seg_max_bytes, 1 * 1024 * 1024),
            .allocator = allocator,
        };
        try w.rotate(); // open first segment
        return w;
    }

    pub fn deinit(self: *Writer) void {
        if (self.file) |*f| f.close();
        self.allocator.free(@constCast(self.dir_path));
        self.* = undefined;
    }

    fn dup(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
        const out = try allocator.alloc(u8, s.len);
        @memcpy(out, s);
        return out;
    }

    fn segPath(self: *Writer, seq: u64, buf: *[64]u8) []const u8 {
        const name = fsu.logName(buf[0..], seq);
        return std.fs.path.join(self.allocator, &.{ self.dir_path, name }) catch name; // fallback if OOM
    }

    fn rotate(self: *Writer) !void {
        if (self.file) |*f| {
            try f.sync();
            f.close();
        }
        var tmp_buf: [64]u8 = undefined;
        const full = self.segPath(self.next_seq, &tmp_buf);
        defer if (full.ptr != tmp_buf[0..].ptr) self.allocator.free(@constCast(full));
        // create/truncate
        var file = try std.fs.cwd().createFile(full, .{ .truncate = true, .read = true, .mode = .{} });
        // ensure the directory metadata is durable
        try file.sync();
        try fsu.syncParentDir(full);
        self.file = file;
        self.written_in_seg = 0;
        self.next_seq += 1;
    }

    pub fn sync(self: *Writer) !void {
        if (self.file) |*f| try f.sync();
    }

    /// Append a single framed record.
    pub fn append(self: *Writer, typ: RecordType, payload: []const u8) !void {
        var f = self.file orelse return error.Closed;
        // 4 bytes len + 1 byte type + payload + 4 bytes crc
        const frame_len: usize = 4 + 1 + payload.len + 4;
        
        // rotate if necessary
        if (self.written_in_seg + frame_len > self.seg_max_bytes) {
        try self.rotate();
        f = self.file.?;
        }

        var lenbuf: [4]u8 = undefined;
        std.mem.writeInt(u32, lenbuf[0..4], @intCast(payload.len + 1), .little);
        var typebuf: [1]u8 = .{ @intFromEnum(typ) };
        const crc = crc32c.sum(typebuf[0..] ++ payload);
        var crcb: [4]u8 = undefined;
        std.mem.writeInt(u32, crcb[0..4], crc, .little);

        // Gathered writes — keep it simple and sequential
        try f.writeAll(lenbuf[0..4]);
        try f.writeAll(typebuf[0..1]);
        try f.writeAll(payload);
        try f.writeAll(crcb[0..4]);

        self.written_in_seg += frame_len;
    }
};

pub const Reader = struct {
    file: std.fs.File,
    consumed: usize = 0,
    file_len: usize,

    pub fn open(path: []const u8) !Reader {
        var f = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        const stat = try f.stat();
        return .{ .file = f, .file_len = @intCast(stat.size) };
    }

    pub fn close(self: *Reader) void { self.file.close(); }

    /// Returns: null on EOF *or* on partial/corrupt tail (safe stop).
    pub fn next(self: *Reader, allocator: std.mem.Allocator) !?struct {
        typ: RecordType,
        payload: []u8, // owned by caller; freed by caller
    } {
        var f = self.file;

        // Need at least 4 bytes for length
        if (self.file_len - self.consumed < 4) return null;

        var lenb: [4]u8 = undefined;
        try f.preadAll(&lenb, self.consumed);
        const raw_len = std.mem.readInt(u32, &lenb, .little);
        if (raw_len == 0) return null; // invalid
        const need_total = 4 + @as(usize, raw_len) + 4; // len + payload+type + crc
        if (self.file_len - self.consumed < need_total) {
            // partial tail, treat as EOF
            return null;
        }

        // Read type + payload
        var tp: [1]u8 = undefined;
        try f.preadAll(&tp, self.consumed + 4);
        const typ: RecordType = @enumFromInt(tp[0]);

        const pay_len = @as(usize, raw_len) - 1;
        const payload = try allocator.alloc(u8, pay_len);
        errdefer allocator.free(payload);
        if (pay_len > 0)
            try f.preadAll(payload, self.consumed + 5);

        // Read crc
        var crcb: [4]u8 = undefined;
        try f.preadAll(&crcb, self.consumed + 4 + 1 + pay_len);
        const on_disk_crc = std.mem.readInt(u32, &crcb, .little);
        const calc_crc = crc32c.sum(tp[0..] ++ payload);

        if (calc_crc != on_disk_crc) {
            // treat as corrupt tail => stop (safe)
            allocator.free(payload);
            return null;
        }

        self.consumed += need_total;

        return .{
            .typ = typ,
            .payload = payload,
        };
    }
};

test "wal: append/read single file, roundtrip" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var writer = try Writer.open(std.heap.page_allocator, tmp.dir_path, 1 << 20);
    defer writer.deinit();

    try writer.append(.Batch, "hello");
    try writer.append(.Batch, "world");
    try writer.sync();

    // open current segment: it's "000001.log"
    var namebuf: [64]u8 = undefined;
    const segname = fsu.logName(&namebuf, 1);
    const path = try std.fs.path.join(std.heap.page_allocator, &.{ tmp.dir_path, segname });
    defer std.heap.page_allocator.free(path);

    var r = try Reader.open(path);
    defer r.close();

    const a = (try r.next(std.heap.page_allocator)) orelse return error.UnexpectedEOF;
    defer std.heap.page_allocator.free(a.payload);
    try std.testing.expectEqual(RecordType.Batch, a.typ);
    try std.testing.expect(std.mem.eql(u8, a.payload, "hello"));

    const b = (try r.next(std.heap.page_allocator)) orelse return error.UnexpectedEOF;
    defer std.heap.page_allocator.free(b.payload);
    try std.testing.expect(std.mem.eql(u8, b.payload, "world"));

    try std.testing.expect((try r.next(std.heap.page_allocator)) == null);
}

test "wal: truncated tail is ignored" {
    const tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var writer = try Writer.open(std.heap.page_allocator, tmp.dir_path, 1 << 20);
    defer writer.deinit();

    // write 3 frames
    try writer.append(.Batch, "a");
    try writer.append(.Batch, "bb");
    try writer.sync();

    // find file path
    var namebuf: [64]u8 = undefined;
    const segname = fsu.logName(&namebuf, 1);
    const path = try std.fs.path.join(std.heap.page_allocator, &.{ tmp.dir_path, segname });
    defer std.heap.page_allocator.free(path);

    // Append a 3rd frame, then simulate a crash by truncating mid-frame
    try writer.append(.Batch, "ccc");
    try writer.sync();

    // Reopen and truncate: we cut off last 2 bytes to simulate torn tail
    var f = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer f.close();
    const st = try f.stat();
    try f.setEndPos(st.size - 2);

    var r = try Reader.open(path);
    defer r.close();

    // Should read only the first two valid frames
    const A = (try r.next(std.heap.page_allocator)) orelse return error.UnexpectedEOF;
    defer std.heap.page_allocator.free(A.payload);
    try std.testing.expect(std.mem.eql(u8, A.payload, "a"));

    const B = (try r.next(std.heap.page_allocator)) orelse return error.UnexpectedEOF;
    defer std.heap.page_allocator.free(B.payload);
    try std.testing.expect(std.mem.eql(u8, B.payload, "bb"));

    // Third should be ignored due to truncation
    try std.testing.expect((try r.next(std.heap.page_allocator)) == null);
}