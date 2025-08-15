# ZiggyDB Development Plan

## What is ZiggyDB?

ZiggyDB is an embedded key-value store written in Zig, designed for high performance and reliability.

## Development Roadmap

1. **Design API surface**  
   *Acceptance Criteria:* Compile-time stable signatures; basic CLI.

2. **Implement varint + crc32c**  
   *Acceptance Criteria:* Property tests + hardware acceleration path if available.

3. **WAL v1 + recovery v1**  
   *Acceptance Criteria:* Group commit; crash-replay idempotent; CRC verified.

4. **Memtable skiplist + flush**  
   *Acceptance Criteria:* Flush produces sorted runs; no data loss on restart.

5. **SSTable format v1**  
   *Acceptance Criteria:* Index, data, footer, checksums; random seek ≤ 2 I/Os.

6. **Bloom filter**  
   *Acceptance Criteria:* FP rate within 10% of target bits/key.

7. **Merging iterator**  
   *Acceptance Criteria:* Ordered scan across mem + SST; tombstones respected.

8. **Compaction engine + manifest**  
   *Acceptance Criteria:* Bounded L0; atomic version installs; stall control.

9. **Transactions (SI) + MVCC**  
   *Acceptance Criteria:* Atomic batch commit; read validation; SI tests pass.

10. **Recovery v2 (manifest + snapshots)**  
    *Acceptance Criteria:* O(1) startup; consistent snapshot/restore.

11. **GC of old versions**  
    *Acceptance Criteria:* No visible version dropped; space bound under churn.

12. **Bench harness + metrics**  
    *Acceptance Criteria:* YCSB mixes; p50/p95/p99 published; dash of observability.

13. **Crash/fault/fuzz suite**  
    *Acceptance Criteria:* Survives randomized kills & corrupt tails.

14. **Operational CLI**  
    *Acceptance Criteria:* inspect/backup/restore/compact commands.

## Current Implementation Status

### Core Features
- [x] Writes WAL entries
- [x] Updates memtable
- [x] Triggers flush → SST when memtable is full
- [x] Appends new SST metadata to MANIFEST

---

## Step 1 — Minimal write path + flush trigger

### Implementation Details
- `DB.open()` sets up arena + memtable + WAL writer
- `DB.put`/`DB.del`:
  - Encode a tiny batch format
  - Append to WAL (fsync optional)
  - Apply to memtable with a monotonically increasing seq
  - If memtable size ≥ `opts.memtable_bytes`, flush to SST, append to MANIFEST, and reset arena/memtable

> **Note:** We won't do recovery or SST reads yet — that's Step 2.

---

## Step 2 — Recovery + SST Reads

### 1. Recovery on Open
- Read MANIFEST to get SSTable list
- Open each SSTable into `sst_files`
- Replay WAL entries after the last flushed sequence into a new memtable

### 2. Read Path
- `DB.get()` first checks memtable (current sequence snapshot)
- If not found, scan SSTables newest first until found

### 3. Minimal SST Reader
- Use `sstable.reader.TableReader` to fetch a key from disk
- We won't add Bloom filters yet — that's Step 3

## Step 3 — Bloom Filters

Next steps involve integrating Bloom filters in the SSTable reader to skip disk scans for definitely-missing keys. This optimization will significantly improve read performance as the dataset grows.

### Expected Benefits
- Reduced disk I/O for non-existent keys
- Improved read throughput
- Better overall system performance under read-heavy workloads
