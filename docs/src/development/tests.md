# ZiggyDB Test Specifications and Results
**Generated on**: 2025-12-06 08:53:22
**Status**: ✅ All Tests Passing (Last Run: 0.09s)

This document details the test cases executed to verify ZiggyDB functionalities.

---

## 1. Storage Engine (SSTable & MemTable)

| Test Name | Description | Methodology | Inputs | Expected Output | Result |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **SSTable Roundtrip** | Verifies that data written to an SSTable can be read back correctly. | 1. Create `TableBuilder`.<br>2. Add Sort Key/Value pairs.<br>3. Finish build.<br>4. Open `TableReader`.<br>5. Query keys. | Keys: `key_0`...`key_N`<br>Values: `val_0`...`val_N` | Reader returns correct values for all keys. | **PASS** |
| **Bloom Filter** | Verifies that the Bloom filter correctly identifies present keys and probabalistically rejects absent ones. | 1. Write keys to SST.<br>2. Query existing keys (Must be True).<br>3. Query non-existing keys (Must be False most of time). | Present: `apple`, `banana`<br>Absent: `zombie` | `apple` -> Found<br>`zombie` -> Not Found (via Filter) | **PASS** |
| **MemTable Basic** | Verifies in-memory skiplist operations. | 1. `Put` keys into MemTable.<br>2. `Get` keys.<br>3. `Delete` keys. | `Put("a", "1")`<br>`Del("a")` | `Get("a")` returns "1" then `null`. | **PASS** |
| **Corruption Handling** | Verifies reader handles truncated or corrupt files gracefully. | 1. Create valid SST.<br>2. Truncate file tail.<br>3. Attempt `TableReader.open`. | Truncated `.sst` file | `open` returns `error.Corrupt` or reader behaves safely. | **PASS** |

---

## 2. Transactions (ACID)

| Test Name | Description | Methodology | Inputs | Expected Output | Result |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Snapshot Isolation** | Verifies that a transaction sees a consistent snapshot of the DB at `read_ts`. | 1. `T1` starts.<br>2. `T2` writes `k=v2` and commits.<br>3. `T1` reads `k`. | `k` initial: `v1`<br>`T2` writes: `v2` | `T1.get(k)` returns `v1` (Snapshot preserved). | **PASS** |
| **Conflict Detection** | Verifies that concurrent metadata modifications to the same key cause a conflict. | 1. `T1` reads `k`.<br>2. `T2` updates `k` and commits.<br>3. `T1` tries to update `k`. | `T1` write `k`<br>`T2` write `k` | `T1.commit()` fails with `error.Conflict`. | **PASS** |
| **Read Your Own Writes** | Verifies a transaction sees its own uncommitted writes. | 1. `T1` puts `k=val`.<br>2. `T1` gets `k` (before commit). | `k=val` | `T1.get(k)` returns `val`. | **PASS** |
| **Bank Transfer** | Simulates a multi-key transfer to verify atomicity. | 1. `Alice=100`, `Bob=0`.<br>2. Txn: `Alice-=50`, `Bob+=50`.<br>3. Commit. | Transfer 50 | Total Sum remains 100. Both updates applied atomically. | **PASS** |

---

## 3. Recovery & WAL

| Test Name | Description | Methodology | Inputs | Expected Output | Result |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **WAL Rotation** | Verifies that `flushNow` creates a new WAL file and updates Manifest. | 1. Write Data (`A`).<br>2. Flush.<br>3. Write Data (`B`). | `A` in Log 1.<br>`B` in Log 2. | Disk contains `...01.log` and `...02.log`. Manifest `log_number` updated. | **PASS** |
| **Fast Startup** | Verifies Recovery uses `log_number` to skip old logs. | 1. Flush (Rotate to Log 2).<br>2. Restart DB.<br>3. Ensure Log 1 is ignored. | Log 1 (Obsolete)<br>Log 2 (Active) | DB recovers Key (`B`) from Log 2. Ignores Log 1. | **PASS** |
| **Log Cleanup** | Verifies `cleanObsoleteLogs` removes old files. | 1. Generate old logs via rotation.<br>2. Call `cleanObsoleteLogs`. | Logs 1, 2, 3 (Active) | Logs 1 & 2 physically deleted. Only Log 3 remains. | **PASS** |

---

## 4. Garbage Collection

| Test Name | Description | Methodology | Inputs | Expected Output | Result |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Concurrent Scan** | Verifies that deleting files (Compaction) doesn't crash active scanners. | 1. Start long-running Scan.<br>2. Concurrently compact/delete scanned files.<br>3. Wait for scan. | `Scan(All)`<br>`Compact` | Scan completes successfully (holding RefCount). Files deleted afterwards. | **PASS** |
| **Safe Deletion** | Verifies files are only deleted when refcount drops to zero. | 1. Grab Version Ref.<br>2. Run GC.<br>3. Unref. | Live Version | Files remain during Ref. Deleted after Unref. | **PASS** |

---

## 5. Stress Testing

| Test Name | Description | Methodology | Inputs | Expected Output | Result |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Chaos/Stress Test** | Model-Based Testing to verify consistency under randomized load. | 1. Loop 5,000 times.<br>2. Randomly `Put`, `Del`, `Flush`, `Compact`, `Restart`.<br>3. Compare DB `Get` vs In-Memory Map. | Random Seed `0`<br>5,000 Ops | 100% Match between DB and Model. No crashes. | **PASS** |

---

**Summary**: The test suite covers all critical subsystems including storage durability, transactional isolation, concurrency safety, and recovery mechanisms. The addition of the Stress Test provides high confidence in stability.
