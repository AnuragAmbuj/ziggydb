# Configuration

The `Options` struct controls database behavior.

```zig
pub const Options = struct {
    /// Directory path for database files.
    path: []const u8,

    /// Max size of MemTable before flush (default: 64MB).
    memtable_bytes: usize = 64 * 1024 * 1024,

    /// SSTable block size (default: 16KB).
    block_size: u32 = 16 * 1024,

    /// Whether to fsync WAL on every commit (default: true).
    /// Set to false for higher write throughput at risk of recent data loss on crash.
    fsync_on_commit: bool = true,
    
    /// Size of LRU Block Cache in bytes (default: 0 = Disabled).
    /// Recommended: 10-20% of available RAM.
    block_cache_bytes: usize = 0,
};
```

## Performance Tuning

- **Write Heavy**: Increase `memtable_bytes` (e.g., 128MB) and disable `fsync_on_commit` (if safety permits).
- **Read Heavy**: Enable `block_cache_bytes` (e.g., 512MB) and use smaller `block_size` (4KB) for random access.
