# Storage Engine

ZiggyDB's storage engine is designed for high performance and reliability, using a log-structured merge-tree (LSM-tree) architecture.

## Implementation Status

✅ **Core Features**
- [x] Write-Ahead Log (WAL) with checksums
- [x] In-memory MemTable with skip list
- [x] Automatic MemTable flush to SSTable (Level 0)
- [x] Leveled Compaction (L0 -> L1)
- [x] Merging Iterator (Range Scans across levels)
- [x] SSTable metadata management in MANIFEST (v3)
- [x] Recovery from WAL and SSTables
- [x] LRU Block Cache

🚧 **In Progress**
- [ ] Transaction support (Conflict detection refined)
- [ ] Bloom filters for SSTables
- [ ] Advanced Compaction (L1 -> L2, etc.)

## Architecture

### 1. MemTable

The MemTable is an in-memory data structure that buffers all writes before they are flushed to disk.

- **Purpose**: Provides fast write performance
- **Implementation**: Uses a skip list for ordered key-value storage
- **Flush**: When size exceeds `opts.memtable_bytes`, it's converted to an SSTable in Level 0 (L0).
- **Thread Safety**: Handles concurrent reads and writes

### 2. Write-Ahead Log (WAL)

The WAL ensures durability by logging all writes before they are applied to the MemTable.

- **Purpose**: Recovers unflushed data after crashes
- **Format**: Binary format with CRC32C checksums
- **Recovery**: Replays the log on startup, handling log rotation.
- **Durability**: Configurable fsync behavior via `fsync_on_commit`

### 3. SSTables (Sorted String Tables)

Immutable on-disk files that store sorted key-value pairs, organized into **7 Levels (L0 - L6)**.

- **Level 0 (L0)**:
  - Created by flushing MemTables.
  - Keys can overlap between files.
  - Sorted by recency (newest to oldest).
- **Level 1 - Level 6 (L1..L6)**:
  - Created by compaction.
  - Files within a level are **disjoint** (non-overlapping key ranges) and sorted.
  - Size targets increase exponentially (e.g., L1=10MB, L2=100MB).
- **File Naming**: 
  - `MANIFEST`: Stores file list, levels, and key ranges (v3 format).
  - `{seq}.sst`: Data files.
  - `{seq}.log`: WAL files.

### 4. Compaction Service

Background process that maintains the LSM-tree structure.

- **L0 -> L1**: Triggered when L0 has too many files. Merges overlapping L0 files into L1.
- **L(N) -> L(N+1)**: Triggered when L(N) exceeds size limit. Picks a file from L(N) and merges with overlapping files in L(N+1).
- **Garbage Collection**: Obsolete files (SST/WAL) are deleted after compaction/flush updates the Manifest.

## Write Path

1. Write is encoded in a batch format.
2. Batch is appended to the WAL (serial persistence).
3. Write is applied to the MemTable.
4. When MemTable is full:
   - Rotates to Immutable MemTable.
   - Rotates WAL to new log file.
   - Flushes Immutable MemTable to a new **Level 0** SSTable.
   - Updates Manifest (Adds new L0 file, Updates Log Number).

## Read Path

1. Check the active MemTable.
2. Check Immutable MemTable (if flushing).
3. **Level 0 Scan**: Iterate L0 files from newest to oldest. Since they overlap, we must check each file that might contain the key.
4. **Level 1..6 Scan**: For each level, find the single file that might overlap the key (using file bounds from Manifest).
5. Return the first matching value found.
6. **Block Cache**: SSTable blocks are cached in an LRU cache to speed up repeated reads.

## Recovery Process

On database startup:

1. Read MANIFEST to get the list of valid SSTables
2. Open each referenced SSTable and verify checksums
3. Find the latest WAL file
4. Replay WAL entries that were not flushed to SSTables
5. Reconstruct the MemTable state

## Configuration Options

- `memtable_bytes`: Maximum size of MemTable before flush (default: 4MB)
- `block_size`: Size of data blocks in SSTables (default: 4KB)
- `fsync_on_commit`: Whether to fsync WAL after each write (default: false)
- `data_dir`: Directory to store database files

1. Check the active MemTable
2. Check immutable MemTables (if any)
3. Check SSTables from newest to oldest
4. Use Bloom filters to skip SSTables that don't contain the key

## Compaction

Process of merging and rewriting SSTables to remove overwritten or deleted data.

- **Leveled Compaction**: SSTables are organized in levels
- **Size-Tiered Compaction**: Groups SSTables of similar sizes
- **Tiered Compaction**: Groups SSTables into tiers based on size and age

## Performance Considerations

- **Write Amplification**: Reduced through careful compaction strategies
- **Read Amplification**: Managed through Bloom filters and caching
- **Space Amplification**: Controlled by compaction policies

## Configuration Options

- MemTable size
- Cache sizes
- Compression

## Next Steps

- [Transaction Model](./transactions.md) - How transactions work with the storage engine
- [File Format](../internals/file-format.md) - Detailed SSTable format
