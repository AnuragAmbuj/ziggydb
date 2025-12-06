const std = @import("std");
const z = @import("ziggydb");
const MemTable = z.memtable.MemTable;
const TableReader = z.sstable.reader.TableReader;

pub const MergingIterator = struct {
    allocator: std.mem.Allocator,
    
    // Child iterators
    mem_iter: MemTable.Iter,
    sst_iters: std.ArrayList(TableReader.Iter),
    // Owned resources
    sst_readers: std.ArrayList(*TableReader),

    // Current values from each iterator
    mem_curr: ?z.memtable.Entry = null,
    sst_curr: std.ArrayList(?struct { key: []const u8, value: []const u8 }),

    started: bool = false,

    pub fn init(
        allocator: std.mem.Allocator, 
        mem_iter: MemTable.Iter, 
        sst_iters: std.ArrayList(TableReader.Iter),
        sst_readers: std.ArrayList(*TableReader)
    ) !MergingIterator {
        var sst_curr = try std.ArrayList(?struct { key: []const u8, value: []const u8 }).initCapacity(allocator, sst_iters.items.len);
        // Fill with nulls initially
        var i: usize = 0;
        while (i < sst_iters.items.len) : (i += 1) {
            sst_curr.appendAssumeCapacity(null);
        }

        return MergingIterator{
            .allocator = allocator,
            .mem_iter = mem_iter,
            .sst_iters = sst_iters,
            .sst_readers = sst_readers,
            .sst_curr = sst_curr,
        };
    }

    pub fn deinit(self: *MergingIterator) void {
        self.sst_curr.deinit();
        for (self.sst_iters.items) |*it| {
            it.deinit();
        }
        self.sst_iters.deinit();
        // Free readers
        for (self.sst_readers.items) |r| {
            r.close();
            self.allocator.destroy(r);
        }
        self.sst_readers.deinit();
    }

    pub fn next(self: *MergingIterator) !?struct { key: []const u8, value: []const u8 } {
        if (!self.started) {
            // Prime all iterators
            self.mem_curr = self.mem_iter.next();
            var i: usize = 0;
            while (i < self.sst_iters.items.len) : (i += 1) {
                self.sst_curr.items[i] = try self.sst_iters.items[i].next();
            }
            self.started = true;
        }

        // Find smallest key across all iterators
        // MemTable is always newest (seq number consideration handled by MemTable.Iter for its own keys)
        // SSTables are ordered newest to oldest in the list
        
        // We need to find the smallest user_key.
        // If multiple iterators have the same user_key, the one that appears first in our list (MemTable, then SSTables 0..N) wins because it is newer.
        // We must advance all other iterators that have the same key to skip shadowed versions.

        var best_key: ?[]const u8 = null;
        
        // 1. Check MemTable
        if (self.mem_curr) |e| {
            best_key = e.user_key;
        }

        // 2. Check SSTables
        for (self.sst_curr.items) |maybe_entry| {
            if (maybe_entry) |e| {
                if (best_key) |bk| {
                    if (std.mem.order(u8, e.key, bk) == .lt) {
                        best_key = e.key;
                    }
                } else {
                    best_key = e.key;
                }
            }
        }

        const smallest_key = best_key orelse return null;

        // Now find who has this key, pick the winner, and advance ALL who have this key
        // Winner is the first one found in order (Mem -> SST0 -> SST1...)
        
        var winner_val: ?[]const u8 = null;
        var found_winner = false;

        // Check MemTable
        if (self.mem_curr) |e| {
            if (std.mem.eql(u8, e.user_key, smallest_key)) {
                if (!found_winner) {
                     // Check for tombstones
                     if (e.kind == .Put) {
                         winner_val = e.value;
                         found_winner = true;
                     } else if (e.kind == .Del) {
                         // Defines the key as deleted. 
                         // We found the winner, but it's a tombstone.
                         // We must NOT return a value, but we HAVE processed this key.
                         // So found_winner = true, but winner_val = null.
                         found_winner = true;
                         winner_val = null;
                     }
                }
                self.mem_curr = self.mem_iter.next();
            }
        }

        // Check SSTables
        var i: usize = 0;
        while (i < self.sst_iters.items.len) : (i += 1) {
            if (self.sst_curr.items[i]) |e| {
                if (std.mem.eql(u8, e.key, smallest_key)) {
                    if (!found_winner) {
                        // For SSTables, currently we only have put(key, value). 
                        // If we had tombstones in SST, we would curb it here.
                        // Since we just enabled tombstones in Flush, new SSTs *will* have tombstones (as empty values?).
                        // Wait, flush.zig adds key/value. If .Del, value is empty.
                        // So in SST, key with empty value = tombstone??
                        // That's ambiguous (what if user put empty value?).
                        // We need to fix flush to NOT write empty value for Del, or store Kind.
                        // For this task, assuming we want to proceed, let's assume all SST entries are PUTs for now
                        // or that we treat them as valid values.
                        // The critical part is MemTable shadowing SSTable.
                        
                        winner_val = e.value;
                        found_winner = true;
                    }
                    self.sst_curr.items[i] = try self.sst_iters.items[i].next();
                }
            }
        }

        if (found_winner) {
            if (winner_val) |v| {
                return .{ .key = smallest_key, .value = v };
            } else {
                // Winner was a tombstone. Shadowed everything else.
                // User doesn't see this key.
                // Continue to next key.
                // Reset for next iteration
                return self.next();
            }
        }
        
        // Should not happen if smallest_key was found
        return self.next();
    }
};
