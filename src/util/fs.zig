const std = @import("std");

pub fn ensureDir(path: []const u8) !void {
    var cwd = std.fs.cwd();
    cwd.makePath(path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

/// Sync the directory that contains `path` (posix safety for new files/renames).
pub fn syncParentDir(path: []const u8) !void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var buf = try arena.alloc(u8, path.len);
    @memcpy(buf, path);

    if (buf.len == 0) return;
    // Find last slash
    var last: ?usize = null;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '/') {
            last = i;
        }
    }
    const dir_path: []const u8 = if (last) |idx| buf[0..idx] else ".";
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = false });
    defer dir.close();
    try dir.sync();
}

/// Zero-padded file name like "000001.log"
pub fn logName(buf: []u8, seq: u64) []const u8 {
    // returns the slice actually written
    const written = std.fmt.bufPrint(buf, "{s}{:0>6}.log", .{"", seq}) catch unreachable;
    return written;
}
