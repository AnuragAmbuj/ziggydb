const std = @import("std");
const z = @import("ziggydb");
const Arena = z.util.arena.Arena;

// Operation kind stored alongside a version
pub const Kind = enum(u8) { Put = 1, Del = 2 };

// A logical versioned entry within the memtable
pub const Entry = struct {
    user_key: []const u8, // not owned; points into arena-dup'd memory
    seq: u64,             // commit sequence; higher = newer
    kind: Kind,
    value: []const u8,    // for Del, value is empty
};

// Comparator: by user_key asc; within same key, seq desc
fn less(a: *const Node, b: *const Node) bool {
    const c = std.mem.order(u8, a.user_key, b.user_key);
    if (c == .lt) return true;
    if (c == .gt) return false;
    // same user key -> newer first (desc)
    return a.seq > b.seq;
}

// Skiplist node
const MaxLevel: u8 = 12;

const Node = struct {
    next: [MaxLevel]?*Node = .{null} ** MaxLevel,
    user_key: []const u8,
    seq: u64,
    kind: Kind,
    value: []const u8,
    level: u8,
};

fn lcgStep(x: *u64) void {
    x.* *%= 6364136223846793005;
    x.* +%= 1;
}

fn randomLevel(seed: *u64) u8 {
    var lvl: u8 = 1;
    // about 1/4 chance to grow each step
    while (lvl < MaxLevel) {
        lcgStep(seed);
        // take two lower bits; grow if both zero ~25%
        if ((@as(u8, @intCast(seed.*)) & 0b11) != 0) break;
        lvl += 1;
    }
    return lvl;
}

// Public MemTable
pub const MemTable = struct {
    arena: *Arena,
    head: *Node,           // sentinel with full height
    size_bytes: usize = 0, // approximate
    rng: u64 = 0xC0FFEE,   // LCG seed

    pub fn init(arena: *Arena) !MemTable {
        // allocate head in arena
        var head_node = try arena.alloc(Node, 1);
        head_node[0] = Node{
            .user_key = &[_]u8{},
            .seq = 0,
            .kind = .Put,
            .value = &[_]u8{},
            .level = MaxLevel,
        };
        return MemTable{
            .arena = arena,
            .head = &head_node[0],
        };
    }

    // Duplicate bytes into arena
    fn adup(self: *MemTable, src: []const u8) ![]u8 {
        return try self.arena.dup(src);
    }

    // Internal search: fills 'update' with predecessors at each level and returns >= node at level 0.
    fn findGE(self: *MemTable, key: []const u8, seq: u64, update: ?*[*] ?*Node) ?*Node {
        var x: *Node = self.head;
        var lvl: i32 = MaxLevel - 1;
        var probe = Node{
            .user_key = key,
            .seq = seq,
            .kind = .Put,
            .value = &[_]u8{},
            .level = 1,
        };

        while (lvl >= 0) : (lvl -= 1) {
            const lvl_cast:u8 = @intCast(lvl);
            while (true) {
                const nx = x.next[lvl_cast];
                if (nx == null) break;
                if (!less(nx.?, &probe)) break; // nx >= probe
                x = nx.?;
            }
            if (update) |u| u[lvl_cast] = x;
        }
        return x.next[0];
    }

    // Insert a version. For Del, pass value = empty slice.
    pub fn putVersion(self: *MemTable, user_key: []const u8, seq: u64, kind: Kind, value: []const u8) !void {
        var preds: [MaxLevel]?*Node = .{null} ** MaxLevel;
        _ = self.findGE(user_key, seq, &preds);

        const lvl = randomLevel(&self.rng);
        var node_mem = try self.arena.alloc(Node, 1);
        node_mem[0] = Node{
            .user_key = try self.adup(user_key),
            .seq = seq,
            .kind = kind,
            .value = if (kind == .Put) try self.adup(value) else &[_]u8{},
            .level = lvl,
        };
        const n = &node_mem[0];

        // splice
        var i: usize = 0;
        while (i < lvl) : (i += 1) {
            const pred = preds[i] orelse self.head;
            n.next[i] = pred.next[i];
            pred.next[i] = n;
        }

        // rough size accounting
        self.size_bytes += user_key.len + value.len + 16;
    }

    // Logical put/delete at commit sequence
    pub fn put(self: *MemTable, seq: u64, key: []const u8, val: []const u8) !void {
        try self.putVersion(key, seq, .Put, val);
    }
    pub fn del(self: *MemTable, seq: u64, key: []const u8) !void {
        try self.putVersion(key, seq, .Del, &[_]u8{});
    }

    // Snapshot read: return newest visible (seq <= read_ts) and not tombstoned
    pub fn get(self: *MemTable, read_ts: u64, key: []const u8) !?[]const u8 {
        var n = self.findGE(key, std.math.maxInt(u64), null);
        while (n) |cur| {
            const ord = std.mem.order(u8, cur.user_key, key);
            if (ord == .gt) return null;       // passed the key
            if (ord == .eq) {
                if (cur.seq <= read_ts) {
                    if (cur.kind == .Del) return null;
                    return cur.value;
                }
            }
            n = cur.next[0];
        }
        return null;
    }

    // Iterator over a user-key range [start, end) (end may be empty = unbounded)
    pub const Iter = struct {
        mt: *MemTable,
        read_ts: u64,
        end: []const u8,
        cur: ?*Node = null,
        // Dedup last yielded user_key
        last_key: []const u8 = &[_]u8{},

        pub fn init(mt: *MemTable, read_ts: u64, start: []const u8, end: []const u8) Iter {
            var it = Iter{ .mt = mt, .read_ts = read_ts, .end = end };
            it.cur = mt.findGE(start, std.math.maxInt(u64), null);
            return it;
        }

        pub fn next(self: *Iter) ?Entry {
            var n = self.cur orelse return null;

            while (n) |cur| {
                // end bound check
                if (self.end.len != 0 and std.mem.order(u8, cur.user_key, self.end) != .lt) {
                    self.cur = null;
                    return null;
                }

                // Skip duplicate user_key versions newer than read_ts; pick the first visible <= read_ts
                const same_as_last = self.last_key.len != 0 and std.mem.eql(u8, self.last_key, cur.user_key);
                if (same_as_last) {
                    // already yielded this user_key; advance to next different key
                    n = cur.next[0];
                    self.cur = n;
                    continue;
                }

                // Find the first visible version for this user_key
                var vis: ?*Node = null;
                var scan: ?*Node = cur;
                while (scan) |p| : (scan = p.next[0]) {
                    if (!std.mem.eql(u8, p.user_key, cur.user_key)) break;
                    if (p.seq <= self.read_ts) {
                        vis = p;
                        break;
                    }
                }

                // Advance cursor to first node of the next user_key
                var adv = scan orelse cur;
                while (adv) |p2| : (adv = p2.next[0]) {
                    if (!std.mem.eql(u8, p2.user_key, cur.user_key)) break;
                }
                self.cur = adv;

                if (vis) |v| {
                    self.last_key = cur.user_key;
                    if (v.kind == .Del) {
                        // tombstoned at snapshot — skip emit
                        continue;
                    }
                    return Entry{
                        .user_key = v.user_key,
                        .seq = v.seq,
                        .kind = v.kind,
                        .value = v.value,
                    };
                }
                // No visible version for this key at read_ts — skip emit
            }
            return null;
        }
    };
};