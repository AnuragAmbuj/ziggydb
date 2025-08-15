const std = @import("std");

pub const Bloom = struct {
    m_bits: u32,   // total bits in filter
    k: u8,         // number of hash functions
    seed: u64,     // salt for hashing
    bits: []u8,    // bitset (owned by this struct's owner)

    pub fn init(allocator: std.mem.Allocator, est_keys: usize, fp_rate: f64, seed: u64) !Bloom {
        // m ≈ -n * ln(p) / (ln2)^2
        const ln2 = 0.6931471805599453;
        const denom = ln2 * ln2;
        const n = @as(f64, @floatFromInt(est_keys));
        const p = if (fp_rate <= 0.0) 0.01 else if (fp_rate >= 0.5) 0.5 else fp_rate;
        var m = @as(usize, @intFromFloat(@ceil((-n * std.math.log(p)) / denom)));
        if (m < 64) m = 64; // minimum size
        // k ≈ (m/n) * ln2
        const kf = (@as(f64, @floatFromInt(m)) / @as(f64, @floatFromInt(std.math.max(usize, est_keys, 1)))) * ln2;
        var k = @as(u8, @intFromFloat(@round(kf)));
        if (k < 1) k = 1;
        if (k > 16) k = 16;

        const m_bits: u32 = @intCast(m);
        const bytes = (m + 7) / 8;
        const bits = try allocator.alloc(u8, bytes);
        @memset(bits, 0);

        return .{ .m_bits = m_bits, .k = k, .seed = seed, .bits = bits };
    }

    pub fn deinit(self: *Bloom, allocator: std.mem.Allocator) void {
        if (self.bits.len != 0) allocator.free(self.bits);
        self.* = .{ .m_bits = 0, .k = 0, .seed = 0, .bits = &.{} };
    }

    pub fn add(self: *Bloom, key: []const u8) void {
        const h1 = fnv1a64(key, self.seed);
        const h2 = rotMix64(h1 ^ (self.seed *% 0x9E3779B97F4A7C15));
        var i: u8 = 0;
        while (i < self.k) : (i += 1) {
            const idx = @as(u64, h1) + @as(u64, i) *% @as(u64, h2);
            self.setBit(@intCast(@as(u32, @intCast(idx % @as(u64, self.m_bits)))));
        }
    }

    pub fn mayContain(self: *const Bloom, key: []const u8) bool {
        const h1 = fnv1a64(key, self.seed);
        const h2 = rotMix64(h1 ^ (self.seed *% 0x9E3779B97F4A7C15));
        var i: u8 = 0;
        while (i < self.k) : (i += 1) {
            const idx = @as(u64, h1) + @as(u64, i) *% @as(u64, h2);
            if (!self.getBit(@intCast(@as(u32, @intCast(idx % @as(u64, self.m_bits)))))) return false;
        }
        return true;
    }

    fn setBit(self: *Bloom, bit: u32) void {
        const byte = bit / 8;
        const mask: u8 = 1 << @intCast(bit % 8);
        self.bits[byte] |= mask;
    }
    fn getBit(self: *const Bloom, bit: u32) bool {
        const byte = bit / 8;
        const mask: u8 = 1 << @intCast(bit % 8);
        return (self.bits[byte] & mask) != 0;
    }

    // FNV-1a 64-bit with extra seed xor
    fn fnv1a64(data: []const u8, seed: u64) u64 {
        var h: u64 = 0xcbf29ce484222325 ^ seed;
        const prime: u64 = 0x100000001b3;
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            h ^= data[i];
            h *%= prime;
        }
        return rotMix64(h);
    }

    // Cheap mixer to disperse bits
    fn rotMix64(x: u64) u64 {
        var v = x;
        v ^= v >> 33;
        v *%= 0xff51afd7ed558ccd;
        v ^= v >> 33;
        v *%= 0xc4ceb9fe1a85ec53;
        v ^= v >> 33;
        return v;
    }
};

test "bloom basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // if you are changing this test, please also update the test in builder.zig
    var bf = try Bloom.init(gpa.allocator(), 1000, 0.01, 0xB100B100B100B100);
    defer bf.deinit(gpa.allocator());

    bf.add("a");
    bf.add("b");
    bf.add("c");

    try std.testing.expect(bf.mayContain("a"));
    try std.testing.expect(bf.mayContain("b"));
    try std.testing.expect(!bf.mayContain("zzz"));
}
