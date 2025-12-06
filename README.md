# ZiggyDB 🚀

![Zig Version](https://img.shields.io/badge/Zig-0.12.0+-orange.svg)
![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)

> **Note**
> 🚧 ZiggyDB is a high-performance, embedded key-value store crafted in Zig. It is designed for learning and embedding in Zig applications.

## 🌟 Key Features

- **Embedded Architecture**: Zero-dependency library that links directly into your application.
- **LSM Tree Storage**: Log-Structured Merge Tree architecture optimized for write-heavy workloads.
- **Leveled Compaction**: 7-Level (L0-L6) compaction strategy minimizing space amplification and read latency.
- **ACID Transactions**: Full Snapshot Isolation support using MVCC (Multi-Version Concurrency Control).
- **Crash Recovery**: Write-Ahead Logging (WAL) with automatic rotation and recovery ensures durability.
- **High Performance**: 
  - **MemTable**: Lock-free SkipList for fast in-memory writes.
  - **Block Cache**: LRU caching for hot data blocks.
  - **Bloom Filters**: Probabilistic filtering to skip unnecessary disk reads.

## 🏗️ Implementation Status

- [x] **Core Engine**: Put/Get/Delete operations
- [x] **Storage**:
    - [x] MemTable (SkipList)
    - [x] SSTables (Sorted String Tables)
    - [x] Manifest V3 (Metadata & Levels)
- [x] **Durability**:
    - [x] Write-Ahead Log (WAL)
    - [x] Crash Recovery
- [x] **Compaction**:
    - [x] Leveled Compaction (L0 -> L1 -> ...)
    - [x] Automated Background Triggering
- [x] **Transactions**:
    - [x] `begin()`, `commit()`, `rollback()`
    - [x] Snapshot Isolation
    - [x] Conflict Detection
- [x] **Performance**:
    - [x] LRU Block Cache
    - [x] Merging Iterators (Scan)

## 🚀 Quick Start

Add ZiggyDB to your project and start using it in minutes.

### Installation

Add to `build.zig.zon`:
```zig
.{
    .dependencies = .{
        .ziggydb = .{ .url = "https://github.com/AnuragAmbuj/ziggydb/archive/main.tar.gz" },
    },
}
```

### Usage Example

```zig
const std = @import("std");
const z = @import("ziggydb");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // 1. Configure
    const opts = z.options.Options{
        .path = "./my_data",
        .memtable_bytes = 4 * 1024 * 1024,
        .block_cache_bytes = 8 * 1024 * 1024,
    };

    // 2. Open DB
    var db = try z.db.DB.open(allocator, opts);
    defer db.close();

    // 3. Transactions
    var txn = db.begin();
    try txn.put("user:1", "Ziggy");
    try txn.commit();

    // 4. Read & Scan
    if (try db.get("user:1")) |val| {
        defer allocator.free(val);
        std.debug.print("Hello {s}!\n", .{val});
    }
}
```

## 📚 Documentation

Detailed documentation is available in the `docs/` folder:

- [Getting Started](docs/src/getting-started/quickstart.md)
- [Configuration Guide](docs/src/guide/configuration.md)
- [Architecture Overview](docs/src/architecture/storage-engine.md)
- [API Reference](docs/src/api/db.md)

## 🛠️ Development

To build and run the test suite:

```bash
# Run all tests
zig build test --summary all
```

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
*Built with ❤️ in Zig*
