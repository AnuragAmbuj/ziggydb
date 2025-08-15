// src/codec/crc32c.zig
const std = @import("std");

// Castagnoli poly 0x1EDC6F41 reflected => 0x82F63B78
const TABLE = blk: {
    var t: [256]u32 = undefined;
    var n: usize = 0;
    while (n < 256) : (n += 1) {
        var c: u32 = @intCast(n);
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const mask: u32 = -(c & 1);
            c = (c >> 1) ^ (0x82F63B78 & mask);
        }
        t[n] = c;
    }
    break :blk t;
};

pub fn sum(bytes: []const u8) u32 {
    var c: u32 = 0xFFFF_FFFF;
    for (bytes) |b| {
        const idx: u32 = (c ^ b) & 0xFF;
        c = (c >> 8) ^ TABLE[@intCast(idx)];
    }
    return ~c;
}

test "crc32c known vectors" {
    try std.testing.expectEqual(@as(u32, 0xE306_9283), sum("123456789"));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), sum(&[_]u8{}));
    try std.testing.expectEqual(@as(u32, 0x2262_0447), sum("ziggy db"));
}
