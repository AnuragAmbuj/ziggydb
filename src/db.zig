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

    // newest last; just basenames like "000123.sst"
    sst_files: std.ArrayList([]u8),

    pub fn open(allocator: std.mem.Allocator, opts: Options) !*DB {
        try z.util.fs.ensureDir(opts.path);

        var self = try allocator.create(DB);

        var arena = try z.util.arena.Arena.init(allocator, 4 * 1024 * 1024);
        const mem = try z.memtable.MemTable.init(&arena);

        const walw = try z.wal.Writer.open(allocator, opts.path, 64 * 1024 * 1024);

        const files = std.ArrayList([]u8).init(allocator);

        self.* = .{
            .allocator = allocator,
            .opts = opts,
            .arena = arena,
            .mem = mem,
            .wal = walw,
            .next_seq = 1,
            .sst_files = files,
        };

        try self.loadManifest();
        try self.replayWal();

        return self;
    }

    pub fn close(self: *DB) void {
        self.wal.deinit();
        for (self.sst_files.items) |p| self.allocator.free(p);
        self.sst_files.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
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
        if (try self.mem.get(ts, key)) |v| return v;

        // Scan SSTs newest-first
        var i: isize = @as(isize, @intCast(self.sst_files.items.len)) - 1;
        while (i >= 0) : (i -= 1) {
            const name = self.sst_files.items[@intCast(i)];
            const full = try std.fs.path.join(self.allocator, &.{ self.opts.path, name });
            defer self.allocator.free(full);

            var tr = z.sstable.reader.TableReader.open(self.allocator, full) catch |e| switch (e) {
                else => continue, // tolerate missing/corrupt table for now
            };
            defer tr.close();

            if (try tr.get(key, self.allocator)) |v| return v;
        }
        return null;
    }

    // ---------------- internals ----------------

    const Kind = z.memtable.Kind;

    fn applyOne(self: *DB, kind: Kind, key: []const u8, value: []const u8) !void {
        const seq = self.next_seq;
        self.next_seq +%= 1;

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        try encodeSingleBatch(&buf, seq, kind, key, value);

        try self.wal.append(.Batch, buf.items);
        if (self.opts.fsync_on_commit) try self.wal.sync();

        if (kind == .Put) {
            try self.mem.put(seq, key, value);
        } else {
            try self.mem.del(seq, key);
        }

        if (self.arena.used >= self.opts.memtable_bytes) {
            try self.flushNow();
        }
    }

    fn flushNow(self: *DB) !void {
        // swap out memtable to minimize stall
        var old_arena = self.arena;
        var old_mem = self.mem;

        self.arena = try z.util.arena.Arena.init(self.allocator, 4 * 1024 * 1024);
        self.mem = try z.memtable.MemTable.init(&self.arena);

        const read_ts = std.math.maxInt(u64);
        const seq_for_file = self.next_seq;

        const fr = try z.flush.flushMemtableToSST(
            self.allocator,
            self.opts.path,
            seq_for_file,
            &old_mem,
            read_ts,
            self.opts.block_size,
        );
        defer {
            self.allocator.free(fr.file_path);
            self.allocator.free(fr.min_key);
            self.allocator.free(fr.max_key);
        }

        // append to manifest
        var m = try z.manifest.Manifest.open(self.allocator, self.opts.path);
        defer m.close();
        const base = std.fs.path.basename(fr.file_path);
        try m.append(self.opts.path, .{
            .seq = fr.seq,
            .file = base,
            .min_key = fr.min_key,
            .max_key = fr.max_key,
        });

        // remember in memory
        const name_copy = try self.allocator.alloc(u8, base.len);
        @memcpy(name_copy, base);
        try self.sst_files.append(name_copy);

        old_arena.deinit();
    }

    fn loadManifest(self: *DB) !void {
        var m = z.manifest.Manifest.open(self.allocator, self.opts.path) catch |e| switch (e) {
            error.BadManifest => return e,
            else => {
                // no manifest yet is fine
                return;
            },
        };
        defer m.close();

        var i: usize = 0;
        while (i < m.entries.len) : (i += 1) {
            const base = m.entries[i].file;
            const copy = try self.allocator.alloc(u8, base.len);
            @memcpy(copy, base);
            try self.sst_files.append(copy);
        }
    }

    fn replayWal(self: *DB) !void {
        // collect *.log in path, sort ascending
        var logs = try listLogFiles(self.allocator, self.opts.path);
        defer {
            for (logs.items) |p| self.allocator.free(p);
            logs.deinit();
        }

        var max_seq: u64 = 0;

        var idx: usize = 0;
        while (idx < logs.items.len) : (idx += 1) {
            const path = logs.items[idx];
            var r = z.wal.Reader.open(path) catch {
                continue; // tolerate missing/corrupt files; reader stops on tail
            };
            defer r.close();

            while (try r.next(self.allocator)) |rec| {
                defer self.allocator.free(rec.payload);
                // Decode our batch and apply
                const res = decodeBatch(rec.payload) catch {
                    break; // stop on corrupt frame tail
                };
                if (res.seq > max_seq) max_seq = res.seq;

                var j: usize = 0;
                while (j < res.entries.len) : (j += 1) {
                    const e = res.entries[j];
                    switch (e.kind) {
                        .Put => try self.mem.put(res.seq, e.key, e.value),
                        .Del => try self.mem.del(res.seq, e.key),
                    }
                }
                // free per-entry dup slices created by decodeBatch
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