pub const codec = struct {
    pub const varint = @import("codec/varint.zig");
    pub const crc32c = @import("codec/crc32c.zig");
};

pub const util = struct {
    pub const arena = @import("util/arena.zig");
    pub const fs    = @import("util/fs.zig");
};

pub const wal       = @import("wal.zig");
pub const memtable  = @import("memtable.zig");
pub const memtable_tests = @import("memtable_test.zig");
pub const merge_iter = @import("merge_iter.zig");
pub const merge_iter_tests = @import("merge_iter_test.zig");
pub const transaction = @import("transaction.zig");
pub const transaction_tests = @import("transaction_test.zig");
pub const version = @import("version.zig");
pub const gc_tests = @import("gc_test.zig");
pub const recover_tests = @import("recover_test.zig");
pub const stress_tests = @import("stress_test.zig");

pub const cache = struct {
    pub const lru = @import("cache/lru.zig");
};

pub const sstable = struct {
    pub const block   = @import("sstable/block.zig");
    pub const bloom   = @import("sstable/bloom.zig");
    pub const builder = @import("sstable/builder.zig");
    pub const reader  = @import("sstable/reader.zig");
    pub const tests   = @import("sstable/sstable_test.zig");
};

// Other components you already have (no-op if they have no tests yet)
pub const compaction = @import("compaction.zig");
pub const db         = @import("db.zig");
pub const options    = @import("options.zig");

pub const flush    = @import("flush.zig");
pub const manifest = @import("manifest.zig");

// main.zig is your CLI/app entrypoint (not needed for tests, but safe to export)
pub const main_mod   = @import("main.zig");

// smoke tests
pub const db_smoke_test = @import("db_smoke_test.zig");
pub const db_recovery_test= @import("db_recovery_test.zig");
pub const db_cache_test = @import("db_cache_test.zig");
pub const db_leveled_test = @import("db_leveled_test.zig");