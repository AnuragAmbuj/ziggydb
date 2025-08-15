// src/util/arena.zig
const std = @import("std");

pub const Arena = struct {
    allocator: std.mem.Allocator,
    page_size: usize,
    pages: std.ArrayListUnmanaged([]u8) = .{},
    head: []u8 = &[_]u8{},
    used: usize = 0,

    pub fn init(a: std.mem.Allocator, page_size: usize) !Arena {
        var ar = Arena{ .allocator = a, .page_size = std.math.max(page_size, 4096) };
        try ar.grow();
        return ar;
    }

    fn grow(self: *Arena) !void {
        const page = try self.allocator.alloc(u8, self.page_size);
        try self.pages.append(self.allocator, page);
        self.head = page;
        self.used = 0;
    }

    pub fn alloc(self: *Arena, comptime T: type, n: usize) ![]T {
        const need = @sizeOf(T) * n;
        const alignment = @alignOf(T);
        var ptr = std.mem.alignPointerOffset(self.head.ptr + self.used, alignment);
        if (ptr == null or (@intFromPtr(ptr.?) - @intFromPtr(self.head.ptr)) + need > self.head.len) {
        try self.grow();
        ptr = std.mem.alignPointerOffset(self.head.ptr + self.used, alignment);
        }
        const offset = @intFromPtr(ptr.?) - @intFromPtr(self.head.ptr);
        self.used = offset + need;
        return @as([*]T, @ptrCast(ptr.?))[0..n];
    }

    pub fn dup(self: *Arena, bytes: []const u8) ![]u8 {
        const out = try self.alloc(u8, bytes.len);
        @memcpy(out, bytes);
        return out;
    }

    pub fn reset(self: *Arena) void {
        for (self.pages.items) |p| self.allocator.free(p);
        self.pages.clearRetainingCapacity();
        self.head = &[_]u8{};
        self.used = 0;
    }

    pub fn deinit(self: *Arena) void { self.reset(); }
};

test "arena alloc & reuse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ar = try Arena.init(gpa.allocator(), 16 * 1024);
    defer ar.deinit();

    const a = try ar.alloc(u64, 1024);
    a[0] = 42;
    try std.testing.expectEqual(@as(u64, 42), a[0]);

    const s = try ar.dup("ziggy");
    try std.testing.expect(std.mem.eql(u8, s, "ziggy"));
}