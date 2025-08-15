pub const Options = struct {
    path: []const u8,
    memtable_bytes: usize = 64 * 1024 * 1024,
    block_size: u32 = 16 * 1024,
    fsync_on_commit: bool = true,
};