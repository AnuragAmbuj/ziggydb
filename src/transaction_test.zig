const std = @import("std");
const z = @import("ziggydb"); // Use module import instead of file import
const testing = std.testing;

test "Transaction - Snapshot Isolation" {
    const allocator = testing.allocator;
    const path = "test_txn_si";
    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const opts = z.Options{ .path = path, .block_size = 4096 };
    var db = try z.DB.open(allocator, opts);
    defer db.close();

    // 1. Setup initial state
    try db.put("foo", "v1");
    try db.put("bar", "v1");

    // 2. Start Txn A
    var txnA = db.begin();
    defer txnA.deinit();

    // 3. Update "foo" in DB (outside Txn A)
    // This simulates another committed transaction B
    try db.put("foo", "v2"); // committed immediately (implicit txn)

    // 4. Txn A should see "v1" (Snapshot Isolation)
    if (try txnA.get("foo")) |v| {
        try testing.expectEqualStrings("v1", v);
    } else return error.NotFound;

    // 5. Txn A writes "bar" -> "v2"
    try txnA.put("bar", "v2");
    
    // 6. Txn A reads "bar" (Read your own writes)
    if (try txnA.get("bar")) |v| {
        try testing.expectEqualStrings("v2", v);
    } else return error.NotFound;

    // 7. Commit Txn A
    try txnA.commit();

    // 8. Verify DB state (latest)
    if (try db.get("foo")) |v| {
        try testing.expectEqualStrings("v2", v);
    }
    if (try db.get("bar")) |v| {
        try testing.expectEqualStrings("v2", v);
    }
}

test "Transaction - Conflict Detection" {
    const allocator = testing.allocator;
    const path = "test_txn_conflict";
    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const opts = z.Options{ .path = path, .block_size = 4096 };
    var db = try z.DB.open(allocator, opts);
    defer db.close();

    try db.put("key", "val1");

    // Txn A starts
    var txnA = db.begin();
    defer txnA.deinit();

    // Txn B starts
    var txnB = db.begin();
    defer txnB.deinit();

    // Txn A writes "key" -> "valA"
    try txnA.put("key", "valA");
    try txnA.commit();

    // Txn B writes "key" -> "valB"
    try txnB.put("key", "valB");
    
    // Txn B commit should fail because "key" changed since Txn B started
    const res = txnB.commit();
    try testing.expectError(error.Conflict, res);
    
    // Check final state: key should be valA
    if (try db.get("key")) |v| {
        try testing.expectEqualStrings("valA", v);
    }
}

test "Transaction - Read Your Own Writes" {
    const allocator = testing.allocator;
    const path = "test_txn_ryow";
    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const opts = z.Options{ .path = path };
    var db = try z.DB.open(allocator, opts);
    defer db.close();

    var txn = db.begin();
    defer txn.deinit();

    try txn.put("k", "v");
    if (try txn.get("k")) |v| {
        try testing.expectEqualStrings("v", v);
    } else return error.Fail;

    try txn.delete("k");
    const v2 = try txn.get("k");
    try testing.expect(v2 == null);
}

test "Transaction - Bank Transfer Scenario" {
    const allocator = testing.allocator;
    const path = "test_txn_bank";
    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const opts = z.Options{ .path = path };
    var db = try z.DB.open(allocator, opts);
    defer db.close();

    // Init accounts
    try db.put("alice", "100");
    try db.put("bob", "50");

    // Transfer 10 from Alice to Bob
    var txn = db.begin();
    defer txn.deinit();

    const baltxt_a = (try txn.get("alice")).?;
    const baltxt_b = (try txn.get("bob")).?;
    
    const bal_a = try std.fmt.parseInt(u64, baltxt_a, 10);
    const bal_b = try std.fmt.parseInt(u64, baltxt_b, 10);
    
    // Modify
    var buf: [32]u8 = undefined;
    try txn.put("alice", try std.fmt.bufPrint(&buf, "{d}", .{bal_a - 10}));
    try txn.put("bob", try std.fmt.bufPrint(&buf, "{d}", .{bal_b + 10}));

    // Commit
    try txn.commit();

    // Verify
    const final_a = (try db.get("alice")).?;
    const final_b = (try db.get("bob")).?;
    
    try testing.expectEqualStrings("90", final_a);
    try testing.expectEqualStrings("60", final_b);
}
