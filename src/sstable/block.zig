const std = @import("std");
const z = @import("ziggydb");
const varint = z.codec.varint;

pub const BlockBuilder = struct {
    buf: std.ArrayList(u8),
    last_key: []const u8 = &[_]u8{},
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) BlockBuilder {
        return .{ .buf = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *BlockBuilder) void { self.buf.deinit(); }

    /// Append an entry. Keys must be appended in strictly increasing order.
    pub fn add(self: *BlockBuilder, key: []const u8, value: []const u8) !void {
        if (self.last_key.len != 0) {
            const ord = std.mem.order(u8, self.last_key, key);
            if (ord != .lt) return error.KeysNotStrictlyIncreasing;
        }

        var tmp: [10]u8 = undefined;
        const nk = varint.put(&tmp, key.len);
        try self.buf.appendSlice(tmp[0..nk]);

        const nv = varint.put(&tmp, value.len);
        try self.buf.appendSlice(tmp[0..nv]);

        try self.buf.appendSlice(key);
        try self.buf.appendSlice(value);

        self.last_key = key;
        self.count += 1;
    }

    pub fn bytes(self: *BlockBuilder) []const u8 { return self.buf.items; }
    pub fn len(self: *BlockBuilder) usize { return self.buf.items.len; }
    pub fn isEmpty(self: *BlockBuilder) bool { return self.count == 0; }
};

pub const BlockIter = struct {
    data: []const u8,
    off: usize = 0,

    pub fn init(data: []const u8) BlockIter { return .{ .data = data }; }

    pub fn next(self: *BlockIter) !?struct { key: []const u8, value: []const u8 } {
        if (self.off >= self.data.len) return null;

        const kd = try varint.get(self.data[self.off..]);
        const klen: usize = @intCast(kd.v);
        self.off += kd.len;

        const vd = try varint.get(self.data[self.off..]);
        const vlen: usize = @intCast(vd.v);
        self.off += vd.len;

        if (self.off + klen + vlen > self.data.len) return error.Corrupted;

        const key = self.data[self.off .. self.off + klen];
        self.off += klen;
        const value = self.data[self.off .. self.off + vlen];
        self.off += vlen;

        return .{ .key = key, .value = value };
    }
};