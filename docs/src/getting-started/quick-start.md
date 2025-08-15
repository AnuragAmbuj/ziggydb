# Quick Start

This guide will help you get started with ZiggyDB by showing you how to perform basic operations.

## Starting the Database

Start the database server:

```bash
zig build run -- --data-dir ./data
```

## Basic Operations

### Using the CLI

Connect to the database using the command-line interface:

```bash
zig build run -- cli
```

### Basic Commands

```
# Set a key-value pair
SET mykey "Hello, ZiggyDB!"

# Get a value by key
GET mykey

# Start a transaction
BEGIN

# Perform operations within a transaction
SET counter 1
INCR counter

# Commit the transaction
COMMIT

# View transaction status
INFO
```

## Using the Zig API

```zig
const std = @import("std");
const ziggydb = @import("ziggydb");

pub fn main() !void {
    // Open or create a database
    var db = try ziggydb.Database.open(
        .{ .path = "./data" },
    );
    defer db.close();

    // Start a transaction
    var txn = try db.beginTransaction();
    defer txn.deinit();

    // Set a value
    try txn.put("greeting", "Hello, ZiggyDB!");

    // Get a value
    if (try txn.get("greeting")) |value| {
        std.debug.print("Value: {s}\n", .{value});
    }

    // Commit the transaction
    try txn.commit();
}
```

## Next Steps

- [Architecture Overview](../architecture/overview.md) - Learn about ZiggyDB's architecture
- [API Reference](../api/zig-api.md) - Detailed API documentation
