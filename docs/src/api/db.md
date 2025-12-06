# DB API

The `DB` struct is the main entry point for ZiggyDB.

## Methods

### `open`
```zig
pub fn open(allocator: std.mem.Allocator, opts: Options) !*DB
```
Opens or creates a database at `opts.path`.
- **Returns**: Pointer to `DB` instance. Caller must call `close`.
- **Errors**: Filesystem errors, Lock errors, or Corruption errors.

### `close`
```zig
pub fn close(self: *DB) void
```
Closes the database, releases resources (cache, files, memory).

### `put`
```zig
pub fn put(self: *DB, key: []const u8, value: []const u8) !void
```
Inserts a key-value pair. Overwrites existing key.
- Thread-safe.
- Persisted to WAL before returning (if `fsync_on_commit=true`).

### `get`
```zig
pub fn get(self: *DB, key: []const u8) !?[]const u8
```
Retrieves the value for a key.
- **Returns**: value as `[]const u8` (owned by caller, must free with `allocator`), or `null` if not found.
- **Note**: Scans MemTables -> L0 -> L1..L6.

### `del`
```zig
pub fn del(self: *DB, key: []const u8) !void
```
Deletes a key (writes a tombstone).

### `scan`
```zig
pub fn scan(self: *DB, start: []const u8, end: []const u8) !MergingIterator
```
Returns an iterator over the range `[start, end)`.
- **MergingIterator**: Merges results from MemTable and all SSTables.
- **Usage**:
  ```zig
  var it = try db.scan("a", "z");
  while (try it.next()) |entry| { ... }
  ```

### `compact`
```zig
pub fn compact(self: *DB, opts: anytype) !void
```
Triggers manual compaction.
- If called with `{}`, it runs auto-selection (`pickCompaction`).
- **Blocking**: Blocks until compaction completes (writing new SSTable).
