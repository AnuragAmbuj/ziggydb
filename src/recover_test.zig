const std = @import("std");
const z = @import("ziggydb");
const testing = std.testing;

test "Recovery V2 - WAL Rotation" {
    const allocator = testing.allocator;
    const path = "test_recover_v2";
    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    {
        const opts = z.Options{ .path = path, .block_size = 4096, .memtable_bytes = 1024 * 1024 };
        var db = try z.DB.open(allocator, opts);
        defer db.close();

        // 1. Write Data A (Will be flushed)
        try db.put("key_a", "val_a");
        
        // 2. Flush
        // This should rotate WAL. Current WAL (e.g. 000001.log) becomes obsolete (log < log_number).
        // New WAL (e.g. 000002.log or similar) starts.
        try db.flushNow();
        
        // 3. Write Data B (In new WAL)
        try db.put("key_b", "val_b");
        
        // 4. Flush again (To test multiple rotations)
        try db.flushNow();
        
        // 5. Write Data C (In newest WAL)
        try db.put("key_c", "val_c");
        
        // DB Closes here
    }

    // 6. Inspect Directory (Optional but good for debugging)
    // We expect multiple .log files if we haven't deleted them yet.
    // Or if cleanObsoleteLogs ran, only 1.
    
    {
        // 7. Restart
        const opts = z.Options{ .path = path };
        var db = try z.DB.open(allocator, opts);
        defer db.close();
        
        // 8. Verify Data
        // key_a is in SST (flushed).
        // key_b is in SST (flushed).
        // key_c is in WAL (recovered).
        
        if (try db.get("key_a")) |v| {
            try testing.expectEqualStrings("val_a", v);
        } else return error.NotFoundA;

        if (try db.get("key_b")) |v| {
            try testing.expectEqualStrings("val_b", v);
        } else return error.NotFoundB;

        if (try db.get("key_c")) |v| {
            try testing.expectEqualStrings("val_c", v);
        } else return error.NotFoundC;
        
        // 9. Run Log GC
        try db.cleanObsoleteLogs();
        
        // 10. Verify OLD logs are gone
        // We wrote 3 keys, flushed twice.
        // Rotations:
        // Start: Log 1 (Assumed)
        // Flush 1: Rotates to Log 2. Log 1 is obsolete.
        // Flush 2: Rotates to Log 3. Log 2 is obsolete.
        // End State: Log 3 is active/latest.
        
        // So we expect only Log 3 to exist.
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var log_counts: usize = 0;
        while (try it.next()) |entry| {
             if (std.mem.endsWith(u8, entry.name, ".log")) {
                 log_counts += 1;
             }
        }
        
        // Depending on implementation, Open might have created Log 4?
        // We restarted DB. `DB.open` creates NEW log?
        // Yes, `next_log_seq` logic in `DB.open` creates a fresh log on startup.
        // So `replayWal` replayed Log 3 (containing key_c).
        // Then DB opened Log 4 for new writes.
        // `cleanObsoleteLogs` reads Manifest.
        // Manifest says `log_number` is ... ?
        // `flushNow` updates `log_number` to the NEW log (the one catching FUTURE writes).
        // So after Flush 2, `log_number` was 3. Key C is in Log 3.
        // Is Key C flushed? No, it's in MemTable/WAL.
        // So Manifest says `log_number` = 3 (Safe point).
        // On Restart: `replayWal` starts at 3.
        // `DB.open` creates Log 4.
        // Does `DB.open` update Manifest to say "Log 4"?
        // No, `DB.open` does NOT write to manifest usually.
        // So Manifest still says `log_number` = 3.
        // So `cleanObsoleteLogs` will keep logs >= 3.
        // So Log 3 (with key_c) and Log 4 (empty) should exist.
        // Log 1 and 2 should be gone.
        
        // We expect 2 logs? Or maybe just 1 if Log 4 isn't created if we strictly follow "active"?
        // But `DB.open` definitely created a new one.
        
        if (log_counts > 2) {
             std.debug.print("Expected <= 2 logs, found {d}\n", .{log_counts});
             return error.GCLogFailed;
        }
    }
}
