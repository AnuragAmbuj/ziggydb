const std = @import("std");

pub fn put(dst: []u8, x: u64) usize {
    var v = x;
    var i: usize = 0;
    while (v >= 0x80) : (v >>= 7) {
        dst[i] = @intCast((v & 0x7f) | 0x80); // type inferred from dst[i] (u8)
        i += 1;
    }
    dst[i] = @intCast(v);
    return i + 1;
}

pub const DecodeError = error{Underflow, Overflow};

pub fn get(src: []const u8) DecodeError!struct { v: u64, len: usize } {
    var x: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const b = src[i];
        x |= (@as(u64, b & 0x7f)) << shift;
        if ((b & 0x80) == 0) return .{ .v = x, .len = i + 1 };
        shift += 7;
        if (shift >= 64) return DecodeError.Overflow;
    }
    return DecodeError.Underflow;
}

test "varint roundtrip pseudo-random" {
    var buf: [10]u8 = undefined;
    var v: u64 = 0xA11CE; // simple deterministic sequence
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        // simple LCG to mix values
        v *%= 6364136223846793005;
        v +%= 1;
        const n = put(&buf, v);
        const d = try get(buf[0..n]);
        try std.testing.expectEqual(v, d.v);
        try std.testing.expectEqual(n, d.len);
    }
}

test "varint known values" {
    var b: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), put(&b, 0));
    try std.testing.expectEqual(@as(usize, 2), put(&b, 128));
    try std.testing.expectEqual(@as(usize, 10), put(&b, 0xFFFF_FFFF_FFFF_FFFF));
}

test "bench varint put 10M" {
    var buf: [10]u8 = undefined;
    var v: usize = 0;
    var i: usize = 0;
    while (i < 10_000_000) : (i += 1) {
        v +%= i;
        _ = put(&buf, @intCast(v));
    }
}
