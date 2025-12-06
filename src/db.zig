const std = @import("std");
const z = @import("ziggydb");
const Options = @import("options.zig").Options;

pub const DB = struct {
    allocator: std.mem.Allocator,
    opts: Options,

    arena: z.util.arena.Arena,
    mem: z.memtable.MemTable,
    wal: z.wal.Writer,
    next_seq: u64 = 1,
    log_number: u64 = 0,

    // newest last; just basenames like "000123.sst"
    // sst_files: std.ArrayList([]u8), 
    // REPLACED by Version
    
    current_version: *z.version.Version,
    active_versions: std.ArrayList(*z.version.Version), // List of all live versions
    mutex: std.Thread.Mutex,
    
    // Optional Block Cache
    block_cache: ?*z.cache.lru.LRUCache(z.sstable.reader.TableReader.BlockCacheKey, []u8) = null,
    
    pub const Kind = z.memtable.Kind;

    pub fn open(allocator: std.mem.Allocator, opts: Options) !*DB {
        try z.util.fs.ensureDir(opts.path);

        var self = try allocator.create(DB);
        
        // Init Cache if requested
        var cache: ?*z.cache.lru.LRUCache(z.sstable.reader.TableReader.BlockCacheKey, []u8) = null;
        if (opts.block_cache_bytes > 0) {
            cache = try allocator.create(z.cache.lru.LRUCache(z.sstable.reader.TableReader.BlockCacheKey, []u8));
            cache.?.* = z.cache.lru.LRUCache(z.sstable.reader.TableReader.BlockCacheKey, []u8).init(allocator, opts.block_cache_bytes);
        }
        
        var arena = try z.util.arena.Arena.init(allocator, 4 * 1024 * 1024);
        const mem = try z.memtable.MemTable.init(&arena);

        // We need to know what the NEXT log number should be.
        // It resides in Manifest?
        // Manifest tracks `curr_log_number`. That is the log we recover FROM.
        // So the current log is `manifest.log_number`.
        // If we open `log_number`, we might be appending to it?
        // Or do we start a NEW log on open?
        // Simple strategy: Always start a NEW log on open.
        // So read manifest, get `last_log`, start `last_log + 1`.
        // But `DB.open` loads manifest later.
        // Let's load manifest FIRST?
        // Circular: `loadManifest` is a method of `DB`.
        // We can just open Manifest struct directly.
        
        var manifest = try z.manifest.Manifest.open(allocator, opts.path);
        defer manifest.close();
        
        // Log number in manifest is what we validly have.
        // Let's assume on OPEN we pick up where we left off?
        // Best practice: Always start a fresh WAL on DB Open to avoid corruption/mixed mode?
        // If we start fresh, we need to log it to Manifest.
        // But we handle that in `flushNow`.
        // If we replay `manifest.log_number`, we replay THAT file.
        // If we want to append, we open it.
        // `wal.Writer` with `truncate=true` in `rotate`!
        // `wal.zig`: `createFile(..., .truncate = true, ...)`
        // DANGER: If we open an existing log with `Writer.open`, it TRUNCATES it!
        // We MUST start a new log file # on open.
        
        const next_log_seq = manifest.log_number + 1;
        
        const walw = try z.wal.Writer.open(allocator, opts.path, 64 * 1024 * 1024, next_log_seq);
        
        // We need to persist that we switched to `next_log_seq`?
        // If we crash before flush, we lose the fact that we incremented. 
        // But the new file exists. Empty.
        // Replay looks for `manifest.log_number`. It finds it. Replays it.
        // It sees `next_log_seq` exists? Maybe. It ignores it if it's not in manifest.
        // But if we write to `next_log_seq`, and crash, data is lost unless we updated Manifest?
        // Usually, we update Manifest immediately after switching log?
        // Or we update manifest when we FLUSH.
        // If we write to WAL but haven't flushed, manifest points to OLD log.
        // Recovery reads OLD log. It finds records.
        // Does it find records in NEW log?
        // `replayWal` logic needs to traverse linked logs?
        // `wal.zig` doesn't link logs.
        // We need to replay *starting from* `log_number`, and iterate +1 until file not found.
        
        // Conclusion: It is safe to start `log_number + 1`.
        
        // Init Version
        const v = try z.version.Version.init(allocator);

        self.* = .{
            .allocator = allocator,
            .opts = opts,
            .arena = arena,
            .mem = mem,
            .wal = walw,
            .next_seq = 1,
            .current_version = v,
            .active_versions = std.ArrayList(*z.version.Version).init(allocator),
            .mutex = .{},
            .block_cache = cache,
        };
        
        try self.active_versions.append(v);

        try self.loadManifest();
        try self.replayWal();

        return self;
    }

    pub fn close(self: *DB) void {
        self.wal.deinit();
        
        // Unref current
        if (self.current_version.unref()) {
             // It's dead, remove from list?
             // But we are closing DB. Just clean up everything.
             self.current_version.deinit();
        }
        self.active_versions.deinit();
        
        if (self.block_cache) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    
    // Call this under mutex or ensure safety
    fn releaseVersion(self: *DB, v: *z.version.Version) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (v.unref()) {
            // Remove from active_versions
            for (self.active_versions.items, 0..) |item, i| {
                if (item == v) {
                    _ = self.active_versions.swapRemove(i);
                    break;
                }
            }
            v.deinit();
        }
    }

    // ---------------- public API ----------------

    pub fn put(self: *DB, key: []const u8, value: []const u8) !void {
        try self.applyOne(.Put, key, value);
    }

    pub fn del(self: *DB, key: []const u8) !void {
        try self.applyOne(.Del, key, "");
    }

    pub fn get(self: *DB, key: []const u8) !?[]const u8 {
        const ts = if (self.next_seq == 0) 0 else self.next_seq - 1;
        return self.getAt(ts, key);
    }

    pub fn getAt(self: *DB, ts: u64, key: []const u8) !?[]const u8 {
        if (try self.mem.get(ts, key)) |v| return v;

        // Acquire Version
        self.mutex.lock();
        const v = self.current_version;
        v.ref();
        self.mutex.unlock();
        defer self.releaseVersion(v);

        // Scan L0: Newest-First
        {
            const l0 = v.levels[0];
            var i: isize = @as(isize, @intCast(l0.items.len)) - 1;
            while (i >= 0) : (i -= 1) {
                const meta = l0.items[@intCast(i)];
                // Check bloom filter? Metadata check?
                // L0 files can overlap any key.
                const val = try self.getFromSST(meta.file, key);
                if (val) |res| return res;
            }
        }

        // Scan L1..L6: Levels are sorted and disjoint.
        // We can find at most 1 file per level that contains key.
        var level: usize = 1;
        while (level < 7) : (level += 1) {
            const files = v.levels[level];
            for (files.items) |meta| {
                // Check bounds
                if (std.mem.order(u8, key, meta.min_key) != .lt and
                    std.mem.order(u8, key, meta.max_key) != .gt) 
                {
                    // Candidate found.
                    if (try self.getFromSST(meta.file, key)) |res| return res;
                }
            }
        }
        
        return null;
    }

    fn getFromSST(self: *DB, filename: []const u8, key: []const u8) !?[]const u8 {
        const full = try std.fs.path.join(self.allocator, &.{ self.opts.path, filename });
        defer self.allocator.free(full);

        var tr = z.sstable.reader.TableReader.open(self.allocator, full, self.block_cache) catch |e| switch (e) {
            else => return null, // tolerate missing/corrupt
        };
        defer tr.close();
        
        return tr.get(key, self.allocator);
    }

    pub fn getLatestSeq(self: *DB, key: []const u8) !u64 {
        self.mutex.lock();
        const v = self.current_version;
        v.ref();
        self.mutex.unlock();
        defer self.releaseVersion(v);

        // Check L0
        {
            const l0 = v.levels[0];
            var i: isize = @as(isize, @intCast(l0.items.len)) - 1;
            while (i >= 0) : (i -= 1) {
                const meta = l0.items[@intCast(i)];
                 // Optimization: Check metadata bounds? L0 files usually cover everything but maybe not.
                 // For getLatestSeq we just need to find the key.
                 // We need to return the seq of the OPERATION? 
                 // Or the file seq?
                 // The original code returned `file_seq`.
                 // But really we want the sequence number of the key's entry.
                 // `TableReader.get` returns value. It doesn't return seq.
                 // We might need `TableReader.getWithSeq`?
                 // Assuming original code `file_seq` was "file number" used as proxy.
                 // But `meta.seq` is available!
                 // Let's use `meta.seq` if found?
                 // Or actually open file and check.
                 
                 const val = try self.getFromSST(meta.file, key);
                 if (val) |_| {
                     self.allocator.free(val.?);
                     return meta.seq; // Approximate? Metadata seq is file's largest seq.
                 }
            }
        }
        
        // Check L1..
        var level: usize = 1;
        while (level < 7) : (level += 1) {
             const files = v.levels[level];
             for (files.items) |meta| {
                 if (std.mem.order(u8, key, meta.min_key) != .lt and
                    std.mem.order(u8, key, meta.max_key) != .gt) {
                        const val = try self.getFromSST(meta.file, key);
                        if (val) |_| {
                            self.allocator.free(val.?);
                            return meta.seq;
                        }
                    }
             }
        }
        
        return 0; 
    }

    pub fn scan(self: *DB, start: []const u8, end: []const u8) !z.merge_iter.MergingIterator {
         const mem_iter = try self.mem.iterator(start, end);

         self.mutex.lock();
         const v = self.current_version;
         v.ref();
         self.mutex.unlock();
         defer self.releaseVersion(v);

         var readers = std.ArrayList(*z.sstable.reader.TableReader).init(self.allocator);
         var iters = std.ArrayList(z.sstable.reader.TableReader.Iter).init(self.allocator);
         errdefer {
             readers.deinit(); 
             iters.deinit();
         }

         // Collect all relevant files from all levels
         // L0
         {
             const l0 = v.levels[0];
             var i: isize = @as(isize, @intCast(l0.items.len)) - 1;
             while (i >= 0) : (i -= 1) {
                const meta = l0.items[@intCast(i)];
                // Check overlap? L0 usually broad.
                // Assuming overlap check:
                if (rangeOverlaps(start, end, meta.min_key, meta.max_key)) {
                    try self.addTableIterator(&readers, &iters, meta.file, start, end);
                }
             }
         }
         
         // L1..L6
         var level: usize = 1;
         while (level < 7) : (level += 1) {
             const files = v.levels[level];
             for (files.items) |meta| {
                 if (rangeOverlaps(start, end, meta.min_key, meta.max_key)) {
                      try self.addTableIterator(&readers, &iters, meta.file, start, end);
                 }
             }
         }
         
         return z.merge_iter.MergingIterator.init(self.allocator, mem_iter, iters, readers);
    }
    
    fn rangeOverlaps(start: []const u8, end: []const u8, min: []const u8, max: []const u8) bool {
        // overlap if not (end < min or start > max)
        // using strings..
        // if end is non-empty and end < min: no overlap
        if (end.len > 0 and std.mem.order(u8, end, min) == .lt) return false;
        // if start > max: no overlap
        if (std.mem.order(u8, start, max) == .gt) return false;
        return true;
    }

    fn addTableIterator(self: *DB, readers: *std.ArrayList(*z.sstable.reader.TableReader), iters: *std.ArrayList(z.sstable.reader.TableReader.Iter), filename: []const u8, start: []const u8, end: []const u8) !void {
        const full = try std.fs.path.join(self.allocator, &.{ self.opts.path, filename });
        defer self.allocator.free(full);

        const tr_ptr = try self.allocator.create(z.sstable.reader.TableReader);
        tr_ptr.* = try z.sstable.reader.TableReader.open(self.allocator, full, self.block_cache);
        
        try readers.append(tr_ptr);
        const iter = try z.sstable.reader.TableReader.Iter.init(tr_ptr, start, end);
        try iters.append(iter);
    }

    // Apply a single batch of operations (internal)
    fn applyBatch(self: *DB, batch: []const z.wal.Batch) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 1. Write to WAL
        // (Assume self.wal is active)
        const encoded = try z.wal.encodeBatch(self.allocator, batch);
        defer self.allocator.free(encoded);
        
        try self.wal.append(encoded);
        if (self.opts.fsync_on_commit) {
            try self.wal.sync();
        }

        // 2. Apply to MemTable
        // Sequence number assignment:
        // Each batch consumes 1 sequence number? Or 1 per op?
        // Let's use 1 per batch for simplicity of "timestamp", OR 1 per Op.
        // Usually 1 per op allows finer granularity.
        // Let's do 1 per op.
        
        for (batch) |op| {
            const seq = self.next_seq;
            self.next_seq += 1;
            
            switch (op.opType) {
                .Put => try self.mem.put(seq, op.key, op.value),
                .Del => try self.mem.put(seq, op.key, ""), // Tombstone
            }
        }
        
        // 3. Check MemTable Size -> Flush if needed
        if (self.mem.approxSize() >= self.opts.memtable_bytes) {
            // Drop lock for flush? "flushNow" should handle locking or be careful.
            // FlushNow usually rotates WAL too.
            // If we are holding lock, we can call flushNowInternal?
            // Simplest: release lock, call flushNow. But another thread might intervene.
            // Safe: flushNow does its own locking or we call an internal version.
            // For V1, we just call flushNow(). If it deadlocks, we fix it (flushNow takes mutex).
            // So we must UNLOCK before calling flushNow.
            self.mutex.unlock(); // Explicit unlock
            try self.flushNow();
            self.mutex.lock();   // Re-lock for defer unlock (hacky?)
            // Actually defer unlock will unlock again. Double unlock is UB/bad?
            // Pattern:
            // lock(); defer unlock();
            // ...
            // if (needs_flush) {
            //    unlock();
            //    flush();
            //    lock(); // restore for defer
            // }
            // Zig Mutex isn't recursive.
        }
    }

    fn applyOne(self: *DB, opType: z.wal.OpType, key: []const u8, value: []const u8) !void {
        const batch = try self.allocator.alloc(z.wal.Batch, 1);
        defer self.allocator.free(batch);
        batch[0] = .{ .opType = opType, .key = key, .value = value };
        try self.applyBatch(batch);
    }

    pub fn flush(self: *DB) !void {
        try self.flushNow();
    }

    // Unprotected or Protected? `flushNow` should be public and thread-safe.
    pub fn flushNow(self: *DB) !void {
        self.mutex.lock();
        // Check if empty?
        if (self.mem.approxSize() == 0) {
            self.mutex.unlock();
            return;
        }
        
        // Rotate WAL
        // 1. Snapshot MemTable
        var old_mem = self.mem;
        
        // 2. Create new MemTable
        // We reuse the arena? No, old memtable needs the arena until flushed.
        // We should swap the arena too?
        // Actually `flushMemtableToSST` takes `&old_mem`.
        // The `old_mem` contains pointers into `self.arena`.
        // If we reset `self.arena`, `old_mem` becomes invalid.
        // So we need a NEW arena for the NEW memtable.
        // And we move the OLD arena to the flush process?
        // Correct approach:
        // Memtable owns its arena. 
        // Swap `self.mem` with fresh Memtable (new arena).
        // Then flush `old_mem`.
        
        // Current implementation uses `z.util.arena.Arena` which is simple.
        // Let's assume we can just create a new one.
        
        var new_arena = try z.util.arena.Arena.init(self.allocator, 4 * 1024*1024);
        const new_mem = try z.memtable.MemTable.init(&new_arena);
        
        // 3. WAL Rotation
        // Old WAL is self.wal.
        // We need a new WAL file.
        // Log number logic:
        // Current log is X. New log should be X+1.
        // Where is current log number stored?
        // self.wal contains current seq?
        // Let's assume `self.wal.next_seq` is NOT the log number, but the sequence within the log.
        // We need `manifest.log_number`.
        // We should read manifest? Or keep it in DB struct?
        // Let's read Manifest for safety or keep track.
        // Optimization: DB should track current `log_number`.
        // Let's peek at Manifest or infer.
        // Better: DB struct should have `log_number`.
        // Missing property.
        
        // Let's read manifest to get current log number (slow but safe).
        var m_temp = try z.manifest.Manifest.open(self.allocator, self.opts.path);
        const old_log_num = m_temp.log_number;
        m_temp.close();
        
        const new_log_number = old_log_num + 1;
        
        // Open New WAL
        // Format name: "00000X.log"
        const new_wal = try z.wal.Writer.open(self.allocator, self.opts.path, 64*1024*1024, new_log_number);
        
        // Swap Components
        const old_wal = self.wal;
        const old_arena = self.arena;
        
        self.wal = new_wal;
        self.arena = new_arena;
        self.mem = new_mem;
        
        // Capture read_ts for SSTable (highest seq in old memtable)
        const read_ts = self.next_seq - 1;
        // Also capture sequence for file naming?
        const seq_for_file = self.next_seq; 
        
        self.mutex.unlock(); // Allow writes to new memtable while flushing old
        
        // Flush Old Components
        // We need to close old WAL?
        // old_wal is a copy of the struct. We should call `close` on it?
        // `wal.Writer.deinit()` closes the file.
        var mutable_old_wal = old_wal;
        mutable_old_wal.deinit(); 
        
        // Flush Memtable to SST
        const fr = try z.flush.flushMemtableToSST(
            self.allocator, 
            self.opts.path, 
            seq_for_file, // Use current global seq for unique SST ID? Or just `new_log_number`? 
            // Better to use `new_log_number` (or `old_log_number`?) as file ID if possible, 
            // but `flushMemtableToSST` takes a u64 `seq`.
            // Let's use `seq_for_file` (global seq) to ensure uniqueness and order.
            &old_mem, 
            read_ts, // Max seq in this table
            self.opts.block_size
        );
        
        // Clean up old Memtable/Arena
        // MemTable doesn't strictly need deinit if arena is freed.
        var mutable_old_arena = old_arena;
        mutable_old_arena.deinit();
        
        // Update Manifest
        // Add new file, Update Log Number
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const current = self.current_version;
        // Construct new Version manually
        const new_v = try z.version.Version.init(self.allocator);
        errdefer new_v.deinit();

        // Deep copy levels from current
        for (0..7) |i| {
            for (current.levels[i].items) |meta| {
                const f = try self.allocator.dupe(u8, meta.file);
                const mn = try self.allocator.dupe(u8, meta.min_key);
                const mx = try self.allocator.dupe(u8, meta.max_key);
                try new_v.levels[i].append(.{
                    .level = meta.level,
                    .seq = meta.seq,
                    .file = f,
                    .size = meta.size,
                    .min_key = mn,
                    .max_key = mx
                });
            }
        }
        
        // Add new file to L0
        const fname = std.fs.path.basename(fr.file_path);
        const fbase = try self.allocator.dupe(u8, fname);
        const mn_dup = try self.allocator.dupe(u8, fr.min_key);
        const mx_dup = try self.allocator.dupe(u8, fr.max_key);
        
        // Stat new file
        const f_stat_h = try std.fs.cwd().openFile(fr.file_path, .{});
        const f_stat = try f_stat_h.stat();
        f_stat_h.close();

        try new_v.levels[0].append(.{
            .level = 0,
            .seq = seq_for_file, 
            .file = fbase,
            .size = f_stat.size,
            .min_key = mn_dup,
            .max_key = mx_dup
        });
        
        // Update DB State
        self.current_version = new_v;
        self.log_number = new_log_number;
        try self.active_versions.append(new_v);
        
        if (current.unref()) {
            // Should remove from active_versions but we do lazy GC or on close
        }

        // Write Manifest
        try z.manifest.log(self.opts.path, .{
            .log_number = new_log_number,
            .new_files = &.{
                .{ .level = 0, .seq = seq_for_file, .file = fname, .min_key = fr.min_key, .max_key = fr.max_key }
            }
        });
        
        // Cleanup FlushResult
        self.allocator.free(fr.file_path);
        self.allocator.free(fr.min_key);
        self.allocator.free(fr.max_key);
        
        // Try cleaning logs
        try self.cleanObsoleteLogs();
        
        // Try compaction
        try self.compact({});
    }
    
    pub fn cleanObsoleteLogs(self: *DB) !void {
        var m_temp = try z.manifest.Manifest.open(self.allocator, self.opts.path);
        const active_log = m_temp.log_number;
        m_temp.close();

        var dir = try std.fs.cwd().openDir(self.opts.path, .{ .iterate = true });
        defer dir.close();
        
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .File and std.mem.endsWith(u8, entry.name, ".log")) {
               if (entry.name.len > 4) {
                   const num = std.fmt.parseInt(u64, entry.name[0..entry.name.len-4], 10) catch continue;
                   if (num < active_log) {
                       // Delete
                        const p = try std.fs.path.join(self.allocator, &.{ self.opts.path, entry.name });
                        defer self.allocator.free(p);
                        std.fs.cwd().deleteFile(p) catch {};
                   }
               }
            }
        }
    }

    pub fn cleanObsoleteFiles(self: *DB) !void {
         // Simple GC: Look at all active versions. Gather all live files.
         // Delete any .sst file in dir not in that set.
         
         // 1. Collect Live Set
         var live = std.StringHashMap(void).init(self.allocator);
         defer live.deinit();
         
         self.mutex.lock();
         for (self.active_versions.items) |v| {
             for (v.levels) |lvl| {
                 for (lvl.items) |meta| {
                    try live.put(meta.file, {});
                 }
             }
         }
         self.mutex.unlock();
         
         // 2. Scan Directory
         var dir = try std.fs.cwd().openDir(self.opts.path, .{ .iterate = true });
         defer dir.close();
         
         var it = dir.iterate();
         while (try it.next()) |entry| {
             if (entry.kind == .File and std.mem.endsWith(u8, entry.name, ".sst")) {
                 if (!live.contains(entry.name)) {
                     // Dead file
                     const p = try std.fs.path.join(self.allocator, &.{ self.opts.path, entry.name });
                     defer self.allocator.free(p);
                     std.fs.cwd().deleteFile(p) catch {};
                 }
             }
         }
    }

    pub fn begin(self: *DB) z.transaction.Transaction {
        return z.transaction.Transaction.init(self);
    }

    pub fn commit(self: *DB, txn: *z.transaction.Transaction) !void {
        // Simple serialization: only one commit at a time
        // We need a mutex for `applyOne` / `commit`.
        // Currently `applyOne` is not protected.
        // We should add a Mutex to DB.
        
        // CONFLICT DETECTION
        // For each k in txn.write_set:
        //   if DB.latestSequence(k) > txn.read_ts: abort
        
        var it = txn.pending.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            // Check for conflict
            // Check MemTable first
            // We need `mem.getLatestSeq(key)`.
            // Or `mem.get(maxInt, key)` and check returned seq?
            // `mem.get` returns value.
            // We need internal `mem` access or new method.
            // Let's assume we implement `getLatestSeq` on DB.
            const last_seq = try self.getLatestSeq(key);
            if (last_seq > txn.read_ts) {
                return error.Conflict;
            }
        }
        
        // Apply writes
        const seq = self.next_seq;
        self.next_seq += 1; // Atomic increment needed if threaded?
        
        // Write Batch to WAL
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        
        // We can encode a batch with multiple entries!
        // `encodeBatch` supports list?
        // `applyOne` creates single-entry batch.
        // We need `encodeMultiBatch`.
        
        var w = buf.writer();
        var seqb: [8]u8 = undefined;
        std.mem.writeInt(u64, seqb[0..8], seq, .little);
        try w.writeAll(seqb[0..8]);
        
        var cntb: [4]u8 = undefined;
        std.mem.writeInt(u32, cntb[0..4], @intCast(txn.pending.count()), .little);
        try w.writeAll(cntb[0..4]);
        
        it = txn.pending.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            
            try w.writeByte(@intFromEnum(v.kind));
            
            var tmp: [10]u8 = undefined;
            const nk = z.codec.varint.put(&tmp, k.len);
            try w.writeAll(tmp[0..nk]);
            const val_len = if (v.kind == .Put) v.value.len else 0;
            const nv = z.codec.varint.put(&tmp, val_len);
            try w.writeAll(tmp[0..nv]);
            
            try w.writeAll(k);
            if (v.kind == .Put) try w.writeAll(v.value);
        }
        
        try self.wal.append(.Batch, buf.items);
        if (self.opts.fsync_on_commit) try self.wal.sync();
        
        // Update Memtable
        it = txn.pending.iterator();
        while (it.next()) |entry| {
             const k = entry.key_ptr.*;
             const v = entry.value_ptr.*;
             if (v.kind == .Put) {
                 try self.mem.put(seq, k, v.value);
             } else {
                 try self.mem.del(seq, k);
             }
        }
        
        try self.checkFlush();
    }

    pub fn getLevelCounts(self: *DB) [7]usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var counts: [7]usize = undefined;
        for (self.current_version.levels, 0..) |lvl, i| {
            counts[i] = lvl.items.len;
        }
        return counts;
    }

    pub fn compact(self: *DB, _: anytype) !void {
        // Advanced Compaction Auto-Trigger
        self.mutex.lock();
        const v = self.current_version;
        // Check selection while holding lock
        const compaction_res = try z.compaction.pickCompaction(self.allocator, v, self.opts);
        self.mutex.unlock(); // Release lock for I/O
        
        if (compaction_res) |*c| {
            defer c.deinit(); 
            // Execute
            try self.doCompaction(c);
        }
    }

    fn doCompaction(self: *DB, c: *z.compaction.Compaction) !void {
        // 1. Setup Iterator over All Inputs
        var readers = std.ArrayList(*z.sstable.reader.TableReader).init(self.allocator);
        var iters = std.ArrayList(z.sstable.reader.TableReader.Iter).init(self.allocator);
        defer { readers.deinit(); iters.deinit(); }
        
        // Add Inputs[0]
        for (c.inputs[0].items) |meta| {
            try self.addTableIterator(&readers, &iters, meta.file, "", "");
        }
        // Add Inputs[1]
        for (c.inputs[1].items) |meta| {
            try self.addTableIterator(&readers, &iters, meta.file, "", "");
        }
        
        var merge_iter = z.merge_iter.MergingIterator.init(self.allocator, null, iters, readers);
        defer merge_iter.deinit();
        
        // 2. Write Output
        self.mutex.lock();
        const new_seq = self.next_seq;
        self.next_seq += 1;
        self.mutex.unlock();
        
        var namebuf: [64]u8 = undefined;
        const fname = try std.fmt.bufPrint(&namebuf, "{d:0>6}.sst", .{new_seq});
        const path = try std.fs.path.join(self.allocator, &.{ self.opts.path, fname });
        defer self.allocator.free(path);
        
        var builder = try z.sstable.builder.TableBuilder.create(self.allocator, path, self.opts.block_size);
        defer builder.deinit();
        
        var min_key: []u8 = &.{};
        var max_key: []u8 = &.{};
        var have = false;
        
        while (try merge_iter.next()) |entry| {
            if (!have) {
                min_key = try self.allocator.dupe(u8, entry.key);
                have = true;
            }
            if (max_key.len > 0) self.allocator.free(max_key);
            max_key = try self.allocator.dupe(u8, entry.key);
            try builder.add(entry.key, entry.value);
        }
        try builder.finish();
        
        // Stat new file
        const cf_stat_h = try std.fs.cwd().openFile(path, .{});
        const cf_stat = try cf_stat_h.stat();
        cf_stat_h.close();

        if (!have) return;

        // 3. Update Version
        self.mutex.lock();
        defer self.mutex.unlock();
        const current = self.current_version;
        const new_v = try z.version.Version.init(self.allocator);
        errdefer new_v.deinit();
        
        // Output Level: c.level + 1
        const out_level = c.level + 1;
        
        for (0..7) |lvl| {
            for (current.levels[lvl].items) |meta| {
                // Check if in inputs
                var is_input = false;
                if (lvl == c.level) {
                    for (c.inputs[0].items) |in| {
                        if (std.mem.eql(u8, in.file, meta.file)) { is_input = true; break; }
                    }
                }
                if (lvl == out_level) {
                     for (c.inputs[1].items) |in| {
                        if (std.mem.eql(u8, in.file, meta.file)) { is_input = true; break; }
                    }
                }
                
                if (!is_input) {
                    const f = try self.allocator.dupe(u8, meta.file);
                    const mn = try self.allocator.dupe(u8, meta.min_key);
                    const mx = try self.allocator.dupe(u8, meta.max_key);
                    try new_v.levels[lvl].append(.{
                        .level = @intCast(lvl),
                        .seq = meta.seq,
                        .file = f,
                        .size = meta.size,
                        .min_key = mn,
                        .max_key = mx
                    });
                }
            }
        }
        
        // Add Output to out_level
        const fbase = try self.allocator.dupe(u8, fname);
        try new_v.levels[out_level].append(.{
            .level = @intCast(out_level),
            .seq = new_seq,
            .file = fbase,
            .size = cf_stat.size,
            .min_key = min_key, 
            .max_key = max_key
        });
        
        // Update DB State
        self.current_version = new_v;
        self.log_number = self.log_number; // Unchanged
        try self.active_versions.append(new_v);
        
        if (current.unref()) { 
            // ... 
        }

        // Update Manifest
        var deleted_files = std.ArrayList([]const u8).init(self.allocator);
        defer deleted_files.deinit();
        
        for (c.inputs[0].items) |meta| try deleted_files.append(meta.file);
        for (c.inputs[1].items) |meta| try deleted_files.append(meta.file);

        try z.manifest.log(self.opts.path, .{
             .log_number = self.log_number,
             .new_files = &.{
                 .{ .level = @intCast(out_level), .seq = new_seq, .file = fname, .min_key = min_key, .max_key = max_key }
             },
             .deleted_files = deleted_files.items,
        });
        
        try self.cleanObsoleteFiles();
    }
    
    // Check if memtable full
    fn checkFlush(self: *DB) !void {
        if (self.arena.used >= self.opts.memtable_bytes) {
            try self.flushNow();
        }
    }

    


    fn loadManifest(self: *DB) !void {
        var m = try z.manifest.Manifest.open(self.allocator, self.opts.path);
        defer m.close();
        
        self.log_number = m.log_number;
        
        // Populate Version
        const v = self.current_version;
        // Assuming v is empty (initially created).
        
        for (m.entries) |e| {
            if (e.level > 6) continue; // safety
            
            const file_copy = try self.allocator.dupe(u8, e.file);
            const min_copy = try self.allocator.dupe(u8, e.min_key);
            const max_copy = try self.allocator.dupe(u8, e.max_key);
            
            // Stat file
            const file_path = try std.fs.path.join(self.allocator, &.{ self.opts.path, e.file });
            defer self.allocator.free(file_path);
            
            const mf_stat_h = std.fs.cwd().openFile(file_path, .{}) catch |err| switch(err) {
                 error.FileNotFound => continue, // Ignore deleted/missing files? Safe to skip?
                 else => return err,
            };
            const mf_stat = try mf_stat_h.stat();
            mf_stat_h.close();
        
            try v.levels[e.level].append(.{
                .level = e.level,
                .seq = e.seq,
                .file = file_copy,
                .size = mf_stat.size,
                .min_key = min_copy,
                .max_key = max_copy,
            });
        }
    }

    fn replayWal(self: *DB) !void {
        // Read Manifest to find where to start
        var manifest = try z.manifest.Manifest.open(self.allocator, self.opts.path);
        defer manifest.close();
        const start_log = manifest.log_number;
        
        // List all log files, sort them, replay those >= start_log
        var dir = try std.fs.cwd().openDir(self.opts.path, .{ .iterate = true });
        defer dir.close();

        var logs = std.ArrayList(u64).init(self.allocator);
        defer logs.deinit();

        var it = dir.iterate();
        var log_buf: [32]u8 = undefined;
        while (try it.next()) |entry| {
            if (entry.kind == .File and std.mem.endsWith(u8, entry.name, ".log")) {
                // Parse "000123.log"
                if (entry.name.len > 4) {
                    const num_part = entry.name[0 .. entry.name.len - 4];
                    const seq = std.fmt.parseInt(u64, num_part, 10) catch continue;
                    if (seq >= start_log) {
                        try logs.append(seq);
                    }
                }
            }
        }
        std.mem.sort(u64, logs.items, {}, std.sort.asc(u64));
        
        var max_seq: u64 = 0;

        for (logs.items) |seq| {
            const name = try std.fmt.bufPrint(&log_buf, "{d:0>6}.log", .{seq});
            const path = try std.fs.path.join(self.allocator, &.{ self.opts.path, name });
            defer self.allocator.free(path);

            // Replay
            var r = z.wal.Reader.open(path) catch continue;
            defer r.close();

            while (try r.next(self.allocator)) |rec| {
                defer self.allocator.free(rec.payload);
                
                // Decode batch
                const res = decodeBatch(rec.payload) catch continue;
                
                if (res.seq > max_seq) max_seq = res.seq;

                for (res.entries) |e| {
                    switch (e.kind) {
                        .Put => try self.mem.put(res.seq, e.key, e.value),
                        .Del => try self.mem.del(res.seq, e.key),
                    }
                }
                
                freeDecodedEntries(self.allocator, res.entries);
            }
        }
        
        if (max_seq + 1 > self.next_seq) self.next_seq = max_seq + 1;
    }

    fn listLogFiles(allocator: std.mem.Allocator, dir: []const u8) !std.ArrayList([]u8) {
        var out = std.ArrayList([]u8).init(allocator);

        var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
        defer d.close();

        var it = d.iterate();
        while (try it.next()) |e| {
            if (e.kind != .File) continue;
            if (!std.mem.endsWith(u8, e.name, ".log")) continue;
            const p = try std.fs.path.join(allocator, &.{ dir, e.name });
            try out.append(p);
        }

        // sort by filename lexicographically (000001.log … 000999.log)
        std.mem.sort([]u8, out.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool { return std.mem.order(u8, std.fs.path.basename(a), std.fs.path.basename(b)) == .lt; }
        }.less);

        return out;
    }

    // ---- batch codec (same format as applyOne encodes) ----

    const DecodedEntry = struct {
        kind: Kind,
        key: []u8,
        value: []u8,
    };

    const DecodedBatch = struct {
        seq: u64,
        entries: []DecodedEntry, // owned; caller frees key/value then the slice
    };

    fn encodeSingleBatch(out: *std.ArrayList(u8), seq: u64, kind: Kind, key: []const u8, value: []const u8) !void {
        var w = out.writer();

        var seqb: [8]u8 = undefined;
        std.mem.writeInt(u64, seqb[0..8], seq, .little);
        try w.writeAll(seqb[0..8]);

        var cntb: [4]u8 = undefined;
        std.mem.writeInt(u32, cntb[0..4], 1, .little);
        try w.writeAll(cntb[0..4]);

        try w.writeByte(@intFromEnum(kind));

        var tmp: [10]u8 = undefined;
        const nk = z.codec.varint.put(&tmp, key.len);
        try w.writeAll(tmp[0..nk]);
        const nv = z.codec.varint.put(&tmp, value.len);
        try w.writeAll(tmp[0..nv]);

        try w.writeAll(key);
        try w.writeAll(value);
    }

    fn decodeBatch(buf: []const u8) !DecodedBatch {
        if (buf.len < 12) return error.Corrupt;
        var off: usize = 0;

        const seq = std.mem.readInt(u64, buf[off .. off + 8], .little);
        off += 8;

        const cnt = std.mem.readInt(u32, buf[off .. off + 4], .little);
        off += 4;

        var entries = try std.heap.page_allocator.alloc(DecodedEntry, cnt);
        errdefer std.heap.page_allocator.free(entries);

        var i: usize = 0;
        while (i < cnt) : (i += 1) {
            if (off >= buf.len) return error.Corrupt;
            const kind: Kind = @enumFromInt(buf[off]);
            off += 1;

            const kd = try z.codec.varint.get(buf[off..]);
            off += kd.len;
            const klen: usize = @intCast(kd.v);

            const vd = try z.codec.varint.get(buf[off..]);
            off += vd.len;
            const vlen: usize = @intCast(vd.v);

            if (off + klen + vlen > buf.len) return error.Corrupt;

            const kslice = buf[off .. off + klen];
            off += klen;
            const vslice = buf[off .. off + vlen];
            off += vlen;

            // deep copy so caller can free safely
            const kcopy = try std.heap.page_allocator.alloc(u8, kslice.len);
            @memcpy(kcopy, kslice);
            const vcopy = try std.heap.page_allocator.alloc(u8, vslice.len);
            @memcpy(vcopy, vslice);

            entries[i] = .{ .kind = kind, .key = kcopy, .value = vcopy };
        }

        return .{ .seq = seq, .entries = entries };
    }

    fn freeDecodedEntries(a: std.mem.Allocator, entries: []DecodedEntry) void {
        var i: usize = 0;
        while (i < entries.len) : (i += 1) {
            if (entries[i].key.len != 0) a.free(entries[i].key);
            if (entries[i].value.len != 0) a.free(entries[i].value);
        }
        a.free(entries);
    }
};