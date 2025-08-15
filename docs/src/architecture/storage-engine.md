# Storage Engine

ZiggyDB's storage engine is designed for high performance and reliability, using a log-structured merge-tree (LSM-tree) architecture.

## Implementation Status

✅ **Core Features**
- [x] Write-Ahead Log (WAL) with checksums
- [x] In-memory MemTable with skip list
- [x] Automatic MemTable flush to SSTable
- [x] SSTable metadata management in MANIFEST
- [x] Recovery from WAL and SSTables

🚧 **In Progress**
- [ ] Bloom filters for SSTables
- [ ] Multi-level compaction
- [ ] Transaction support

## Architecture

### 1. MemTable

The MemTable is an in-memory data structure that buffers all writes before they are flushed to disk.

- **Purpose**: Provides fast write performance
- **Implementation**: Uses a skip list for ordered key-value storage
- **Flush**: When size exceeds `opts.memtable_bytes`, it's converted to an SSTable
- **Thread Safety**: Handles concurrent reads and writes

### 2. Write-Ahead Log (WAL)

The WAL ensures durability by logging all writes before they are applied to the MemTable.

- **Purpose**: Recovers unflushed data after crashes
- **Format**: Binary format with CRC32C checksums
- **Recovery**: Replays the log on startup
- **Durability**: Configurable fsync behavior via `fsync_on_commit`

### 3. SSTables (Sorted String Tables)

Immutable on-disk files that store sorted key-value pairs.

- **Structure**:
  - Data blocks (key-value pairs)
  - Index blocks (pointers to data blocks)
  - Footer (metadata and checksums)
- **Levels**: Currently using a single level (L0)
- **File Naming**: `MANIFEST-{seq}.log` for metadata, `{number}.sst` for data

### 4. Bloom Filters (Planned)

Probabilistic data structures that quickly determine if a key might be in an SSTable.

- **Purpose**: Will reduce disk I/O for non-existent keys
- **Status**: Implementation in progress

## Write Path

1. Write is encoded in a batch format
2. Batch is appended to the WAL (with optional fsync)
3. Write is applied to the MemTable with a monotonically increasing sequence number
4. When MemTable size ≥ `opts.memtable_bytes`:
   - It becomes immutable
   - A new MemTable is created
   - The old one is asynchronously flushed to disk as an SSTable
   - New SSTable metadata is appended to MANIFEST

## Read Path

1. Check the active MemTable
2. If not found, check immutable MemTables (if any)
3. If still not found, search SSTables from newest to oldest
4. Return the first matching value found (or `null` if not found)

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
- SSTable size
- Compaction strategy
- Cache sizes
- Compression

## Next Steps

- [Transaction Model](./transactions.md) - How transactions work with the storage engine
- [File Format](../internals/file-format.md) - Detailed SSTable format
