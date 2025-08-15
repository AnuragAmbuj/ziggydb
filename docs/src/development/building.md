# Building from Source

This guide explains how to build ZiggyDB from source, including advanced build options and development workflows.

## Prerequisites

- Zig 0.11.0 or later
- CMake 3.20 or later
- Git
- (Optional) clang for some dependencies

## Basic Build

```bash
git clone https://github.com/yourusername/ziggydb.git
cd ziggydb
zig build
```

This will create:
- `zig-out/bin/ziggydb` - Main executable
- `zig-out/lib/libziggydb.a` - Static library
- `zig-out/include/` - C headers (if applicable)

## Build Options

### Build Modes

Zig supports different build modes:

```bash
# Debug build (default)
zig build

# Release-safe (optimized with runtime safety checks)
zig build -Drelease-safe

# Release-fast (maximum optimization, minimal safety)
zig build -Drelease-fast

# Release-small (optimized for size)
zig build -Drelease-small
```

### Build Targets

Build specific components:

```bash
# Build only the library
zig build lib

# Build only the CLI
zig build cli

# Build and run tests
zig build test

# Build and run benchmarks
zig build bench
```

## Development Workflow

### Running Tests

Run all tests:

```bash
zig build test
```

Run a specific test:

```bash
zig build test --test-filter test_name
```

### Debugging

Use `zig build` with the `-fno-emit-bin` flag to debug:

```bash
zig build test -fno-emit-bin -- test_name
```

### Code Formatting

Format all source files:

```bash
zig fmt src/ tests/
```

### Documentation

Build the documentation:

```bash
cd docs
mdbook build
```

Serve documentation locally:

```bash
cd docs
mdbook serve --open
```

## Cross-Compilation

Zig makes cross-compilation easy. For example, to build for Linux x86_64 from macOS:

```bash
zig build -Dtarget=x86_64-linux-gnu
```

## IDE Support

### VS Code

1. Install the "Zig Language Server" extension
2. Add this to your `settings.json`:

```json
{
    "zig.path": "zig"
}
```

### CLion / IntelliJ

1. Install the "Zig" plugin
2. Configure the Zig SDK path in Settings > Languages & Frameworks > Zig

## Troubleshooting

### Common Issues

1. **Build fails with missing dependencies**
   - Ensure all system dependencies are installed
   - Run `zig build --verbose` for more detailed error messages

2. **Linker errors**
   - Make sure you have the required system libraries
   - Check that your Zig installation is not corrupted

3. **Test failures**
   - Run tests with `--verbose` for more output
   - Check for environment-specific issues

## Next Steps

- [Contributing](../development/contributing.md) - Guidelines for contributing to ZiggyDB
- [Testing](./testing.md) - Writing and running tests
