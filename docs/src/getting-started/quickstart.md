# Quickstart Guide

## Installation

Add **ZiggyDB** to your `build.zig.zon`:

```zig
.{
    .name = "my-app",
    .version = "0.1.0",
    .dependencies = .{
        .ziggydb = .{
            .url = "https://github.com/user/ziggydb/archive/master.tar.gz",
            // .hash = "...",
        },
    },
}
```

In your `build.zig`:

```zig
const ziggydb = b.dependency("ziggydb", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("ziggydb", ziggydb.module("ziggydb"));
```

## Basic Usage

```zig
const std = @import("std");
const z = @import("ziggydb");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Configure
    const opts = z.options.Options{
        .path = "./data",
        .memtable_bytes = 4 * 1024 * 1024,
        .block_cache_bytes = 8 * 1024 * 1024, // 8MB Cache
    };

    // 2. Open DB
    var db = try z.db.DB.open(allocator, opts);
    defer db.close();

    // 3. Write
    try db.put("user:1", "Alice");
    try db.put("user:2", "Bob");

    // 4. Read
    if (try db.get("user:1")) |val| {
        defer allocator.free(val);
        std.debug.print("Found: {s}\n", .{val});
    }

    // 5. Scan
    var it = try db.scan("user:1", "user:3");
    defer it.deinit();
    
    while (try it.next()) |entry| {
        std.debug.print("{s} => {s}\n", .{entry.key, entry.value});
    }
}
```
