# Testing ZiggyDB

This guide covers how to write and run tests for ZiggyDB, including unit tests, integration tests, and benchmarks.

## Test Organization

Tests are organized as follows:

- `src/` - Source code with inline tests
- `tests/` - Integration and end-to-end tests
- `bench/` - Benchmark tests

## Running Tests

### Running All Tests

```bash
zig build test
```

### Running Specific Tests

Run tests matching a pattern:

```bash
zig build test --test-filter "pattern"
```

Run tests with verbose output:

```bash
zig build test --verbose
```

### Running Benchmarks

```bash
zig build bench
```

## Writing Tests

### Unit Tests

Add tests in the same file as the code being tested using `test` blocks:

```zig
test "example test" {
    try std.testing.expectEqual(@as(i32, 4), 2 + 2);
}
```

### Integration Tests

Create test files in the `tests/` directory:

```zig
// tests/my_test.zig
const std = @import("std");
const testing = std.testing;
const ziggydb = @import("ziggydb");

test "integration test" {
    // Test code here
}
```

### Benchmark Tests

Create benchmark files in the `bench/` directory:

```zig
// bench/my_bench.zig
const std = @import("std");
const testing = std.testing;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const allocator = arena.allocator();
    
    // Benchmark code here
}
```

## Test Helpers

### Test Allocator

Use `std.testing.allocator` for memory leak detection:

```zig
test "allocator test" {
    var list = std.ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    
    try list.append(42);
    try testing.expectEqual(@as(u8, 42), list.items[0]);
}
```

### Expect Functions

Use the `std.testing` expect functions:

```zig
try testing.expect(true);
try testing.expectEqual(42, 42);
try testing.expectStringEq("hello", "hello");
```

## Test Coverage

Generate test coverage report:

```bash
zig build test -Dtest-coverage
```

## Continuous Integration

ZiggyDB uses GitHub Actions for CI. The workflow runs:
- Build on multiple platforms
- Run all tests
- Check code formatting
- Generate documentation

## Debugging Tests

Run a specific test in the debugger:

```bash
zig test path/to/test.zig -fno-emit-bin -O Debug
```

## Next Steps

- [Contributing](../development/contributing.md) - Guidelines for contributing
- [Building from Source](../development/building.md) - Build system documentation
