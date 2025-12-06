test "run all module tests" {
    const z = @import("ziggydb");

    // primitives
    _ = z.codec.varint;
    _ = z.codec.crc32c;

    // utils
    _ = z.util.arena;
    _ = z.util.fs;

    // core
    _ = z.wal;
    _ = z.memtable_tests;

    // sstable
    _ = z.sstable.block;
    _ = z.sstable.bloom;
    _ = z.sstable.builder;
    _ = z.sstable.reader;
    _ = z.sstable.tests;

    // extras (compile coverage)
    _ = z.cache;
    _ = z.compaction;
    _ = z.db;
    _ = z.options;
    _ = z.transaction;
    _ = z.transaction_tests;

    // flush and manifest
    _ = z.flush;
    _ = z.manifest;

    _ = z.db_smoke_test;
    _ = z.db_recovery_test;
    _ = z.db_cache_test;
    _ = z.db_leveled_test;
}