pub const codec = struct {
    pub const varint = @import("codec/varint.zig");
    pub const crc32c = @import("codec/crc32c.zig");
};

pub const util = struct {
    pub const arena = @import("util/arena.zig");
    pub const fs    = @import("util/fs.zig");
    pub const buf   = @import("util/buf.zig");
    pub const rand  = @import("util/rand.zig");
};

pub const wal       = @import("wal.zig");
pub const memtable  = @import("memtable.zig");
pub const memtable_tests = @import("memtable_test.zig");

pub const sstable = struct {
    pub const block   = @import("sstable/block.zig");
    pub const bloom   = @import("sstable/bloom.zig");
    pub const builder = @import("sstable/builder.zig");
    pub const reader  = @import("sstable/reader.zig");
    pub const tests   = @import("sstable/sstable_test.zig");
};

// Other components you already have (no-op if they have no tests yet)
pub const cache      = @import("cache.zig");
pub const compaction = @import("compaction.zig");
pub const db         = @import("db.zig");
pub const lib        = @import("lib.zig");
pub const mvcc       = @import("mvcc.zig");
pub const options    = @import("options.zig");
pub const txn        = @import("txn.zig");

pub const flush    = @import("flush.zig");
pub const manifest = @import("manifest.zig");

// main.zig is your CLI/app entrypoint (not needed for tests, but safe to export)
pub const main_mod   = @import("main.zig");

// smoke tests
pub const db_smoke_test = @import("db_smoke_test.zig");
pub const db_recovery_test= @import("db_recovery_test.zig");