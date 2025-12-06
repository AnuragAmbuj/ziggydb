# Transaction API

ZiggyDB supports Snapshot Isolation transactions.

## Usage

```zig
var txn = db.begin();
defer txn.deinit();

try txn.put("k1", "v1");
try txn.get("k1"); // Reads your own writes

try txn.commit(); // Atomic commit
```

## Methods

### `db.begin`
```zig
pub fn begin(self: *DB) Transaction
```
Starts a new transaction. Snapshots the current sequence number (`read_ts`).

### `txn.put` / `txn.del`
Buffers writes in the transaction object. Not visible to other readers until commit.

### `txn.get`
```zig
pub fn get(self: *Transaction, key: []const u8, allocator: std.mem.Allocator) !?[]const u8
```
Reads value. Checks:
1. Pending writes in transaction.
2. DB state at `read_ts`.

### `txn.commit`
```zig
pub fn commit(self: *Transaction) !void
```
Commits changes to DB.
- **Conflict Detection**: Checks if keys modified by this transaction have been modified by others since `read_ts`.
- **Errors**: `error.Conflict` if conflict detected.
