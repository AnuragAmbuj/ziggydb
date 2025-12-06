const std = @import("std");
const z = @import("ziggydb");
const testing = std.testing;

// Model-Based Stress Test
// Performs a long sequence of random operations against ZiggyDB and checks consistency against a HashMap.

test "Stress Test - Random Ops & Restarts" {
    const allocator = testing.allocator;
    const path = "test_stress";
    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};
    
    // Model Reference
    var model = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = model.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        model.deinit();
    }
    
    // Config
    const iterations = 5000;
    const key_space = 100;
    
    var prng = std.rand.DefaultPrng.init(0);
    const rand = prng.random();
    
    // Initialize DB
    const opts = z.Options{ .path = path, .block_size = 1024, .memtable_bytes = 100 * 1024 };
    var db = try z.DB.open(allocator, opts);
    
    var buf: [64]u8 = undefined;
    var val_buf: [64]u8 = undefined;

    for (0..iterations) |i| {
        const op = rand.intRangeAtMost(u8, 0, 10);
        const k_int = rand.intRangeAtMost(u64, 0, key_space);
        const k_str = try std.fmt.bufPrint(&buf, "key_{d:0>5}", .{k_int});
        
        // 10% chance to Close/Reopen
        if (op == 0) {
            db.close();
            // Maybe tamper with files? (Simulate crash? No, just restart)
            db = try z.DB.open(allocator, opts);
            continue;
        }
        
        // 10% chance to Flush
        if (op == 1) {
            try db.flushNow();
            continue;
        }
        
        // 5% chance to Compact (Manual)
        if (op == 2 and (i % 2 == 0)) {
            // Need files input, let's just trigger clean logs or files
            try db.cleanObsoleteFiles();
            try db.cleanObsoleteLogs();
            continue;
        }
        
        // 40% Put
        if (op >= 3 and op <= 6) {
            const v_int = rand.int(u64);
            const v_str = try std.fmt.bufPrint(&val_buf, "val_{d}", .{v_int});
            
            // Apply to DB
            try db.put(k_str, v_str);
            
            // Apply to Model
            const v_copy = try allocator.dupe(u8, v_str);
            if (model.fetchPut(k_str, v_copy)) |kv| {
                allocator.free(kv.value);
            } else |_| {}
        }
        
        // 20% Delete
        if (op >= 7 and op <= 8) {
             try db.del(k_str);
             
             if (model.fetchRemove(k_str)) |kv| {
                 allocator.free(kv.value);
             }
        }
        
        // 15% Get (Verification)
        if (op >= 9) {
            const db_val = try db.get(k_str);
            const model_val = model.get(k_str);
            
            if (model_val) |mv| {
                if (db_val) |dv| {
                    if (!std.mem.eql(u8, mv, dv)) {
                         std.debug.print("Mismatch at i={d} key={s}. Expected {s}, got {s}\n", .{i, k_str, mv, dv});
                         return error.ModelMismatch;
                    }
                } else {
                    std.debug.print("Mismatch at i={d} key={s}. Expected {s}, got NULL\n", .{i, k_str, mv});
                    return error.ModelMismatch;
                }
            } else {
                if (db_val) |dv| {
                     std.debug.print("Mismatch at i={d} key={s}. Expected NULL, got {s}\n", .{i, k_str, dv});
                     return error.ModelMismatch;
                }
            }
        }
    }
    
    // Final Verification
    var it = model.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        const db_val = (try db.get(k)).?; // Must exist
        try testing.expectEqualStrings(v, db_val);
    }
    
    db.close();
}
