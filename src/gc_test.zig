const std = @import("std");
const z = @import("ziggydb");
const testing = std.testing;

test "Concurrent Scan and Compaction" {
    // This test simulates a scanner reading while compaction happens
    // Since Zig test runner is single-threaded by default for `test "..."`,
    // we need to spawn threads using std.Thread.
    
    // HOWEVER: `std.testing.allocator` is not thread-safe in all Zig versions (it uses a mutex in newer ones).
    // Let's use GPA.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const path = "test_gc_concurrency";
    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const opts = z.Options{ .path = path, .block_size = 4096, .memtable_bytes = 1024 * 1024 };
    var db = try z.DB.open(allocator, opts);
    defer db.close();

    // 1. Populate DB with enough data to create multiple SSTs
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d:0>5}", .{i});
        try db.put(key, "val_initial");
    }
    // Force flushes
    try db.flushNow(); // Creates SST 1

    while (i < 1000) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d:0>5}", .{i});
        try db.put(key, "val_second");
    }
    try db.flushNow(); // Creates SST 2
    
    // Create a context for the thread
    const ThreadCtx = struct {
        db: *z.DB,
        done: std.atomic.Value(bool),
        
        fn scanner(ctx: *@This()) !void {
            var cycles: usize = 0;
            while (!ctx.done.load(.monotonic)) {
                // Scan all keys
                var iter = try ctx.db.scan("", "");
                defer iter.deinit();
                while (try iter.next()) |_| {}
                cycles += 1;
                std.time.sleep(10 * std.time.ns_per_ms);
            }
            std.debug.print("Scanner completed {d} cycles\n", .{cycles});
        }
    };
    
    var ctx = ThreadCtx{ .db = db, .done = std.atomic.Value(bool).init(false) };
    
    // Spawn scanner thread
    const t = try std.Thread.spawn(.{}, ThreadCtx.scanner, .{&ctx});
    
    // ... (previous scanner logic)
    
    // Main thread performs compaction
    // Compact SST 1 and SST 2
    {
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var inputs = std.ArrayList([]u8).init(allocator);
        defer {
            for (inputs.items) |s| allocator.free(s);
            inputs.deinit();
        }
        
        while (try it.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".sst")) {
                const copy = try allocator.dupe(u8, entry.name);
                try inputs.append(copy);
            }
        }
        
        if (inputs.items.len >= 2) {
            const input_slice = try allocator.alloc([]const u8, inputs.items.len);
            defer allocator.free(input_slice);
            for (inputs.items, 0..) |item, idx| input_slice[idx] = item;
            
            try db.compact(input_slice);
        }
    }
    
    // GC Check 1: Readers still active?
    // Scanner thread is running. It might be holding old versions.
    // If we run `cleanObsoleteFiles` now, it should NOT delete files held by Scanner.
    // However, it's hard to deterministically know what Scanner is holding without synchronization points.
    // Scanner loop sleeps 10ms.
    
    std.time.sleep(500 * std.time.ns_per_ms);
    ctx.done.store(true, .release);
    t.join();
    
    // Readers are done. Old versions should be unref'd inside `db.scan` (defer loop).
    // So ref counts should drop to 0. Is `active_versions` updated?
    // `defer self.releaseVersion(v)` in scan updates list immediately.
    // So by now, old versions should be goners from `active_versions`?
    // Let's force GC.
    
    try db.cleanObsoleteFiles();
    
    // Check if old SSTs are gone.
    // New SST should be present.
    // Basic check: count .sst files.
    // We started with 2 SSTs. Compacted them into 1.
    // Total should be 1.
    
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var sst_count: usize = 0;
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".sst")) {
            sst_count += 1;
        }
    }
    
    // If GC worked, we should have 1 file.
    if (sst_count != 1) {
        std.debug.print("GC Failed: Expected 1 SST, found {d}\n", .{sst_count});
        return error.GCFailed;
    }
    
    // Verify data integrity
    if (try db.get("key_00000")) |v| {
        try testing.expectEqualStrings("val_initial", v);
    } else return error.NotFound;
}
