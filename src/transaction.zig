const std = @import("std");
const z = @import("ziggydb");
const DB = z.db.DB;

pub const Entry = struct {
    kind: z.memtable.Kind,
    value: []const u8, // Owned by the Transaction (in arena or map)
};

pub const Transaction = struct {
    db: *DB,
    read_ts: u64,
    allocator: std.mem.Allocator,
    
    // key -> Entry
    pending: std.StringHashMap(Entry),
    
    // We can use an arena for keys and values copied into pending
    arena: std.heap.ArenaAllocator,

    pub fn init(db: *DB) Transaction {
        // read_ts is the current state of DB
        // If next_seq=1, read_ts=0.
        // If next_seq=100, valid versions are < 100?
        // memtable stores seq. read_ts should be proper.
        // DB.get uses `if (self.next_seq == 0) 0 else self.next_seq - 1`.
        const read_ts = if (db.next_seq == 0) 0 else db.next_seq - 1;
        
        return Transaction{
            .db = db,
            .read_ts = read_ts,
            .allocator = db.allocator, // or passed separately?
            .pending = std.StringHashMap(Entry).init(db.allocator),
            .arena = std.heap.ArenaAllocator.init(db.allocator),
        };
    }

    pub fn deinit(self: *Transaction) void {
        self.pending.deinit();
        self.arena.deinit();
    }

    pub fn put(self: *Transaction, key: []const u8, value: []const u8) !void {
        try self.addPending(key, value, .Put);
    }
    
    pub fn delete(self: *Transaction, key: []const u8) !void {
        try self.addPending(key, "", .Del);
    }

    fn addPending(self: *Transaction, key: []const u8, value: []const u8, kind: z.memtable.Kind) !void {
        // Deep copy key/value into txn arena
        const k = try self.arena.allocator().dupe(u8, key);
        const v = if (value.len > 0) try self.arena.allocator().dupe(u8, value) else "";
        
        try self.pending.put(k, .{ .kind = kind, .value = v });
    }

    pub fn get(self: *Transaction, key: []const u8) !?[]const u8 {
        // 1. Check pending writes
        if (self.pending.get(key)) |e| {
            if (e.kind == .Del) return null;
            return e.value;
        }
        
        // 2. Check DB snapshot
        // We need a way to read from DB at specific timestamp
        return self.db.getAt(self.read_ts, key);
    }
    
    pub fn commit(self: *Transaction) !void {
        try self.db.commit(self);
    }
};
