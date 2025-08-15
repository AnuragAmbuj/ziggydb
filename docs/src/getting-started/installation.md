# Installation

This guide will help you install ZiggyDB on your system.

## Prerequisites

- Zig 0.11.0 or later
- Git
- CMake 3.20 or later (for building dependencies)

## Installing from Source

1. Clone the repository:

```bash
git clone https://github.com/yourusername/ziggydb.git
cd ziggydb
```

2. Build the project:

```bash
zig build
```

This will create the following artifacts:

- `zig-out/bin/ziggydb` - The main database binary
- `zig-out/lib/libziggydb.a` - Static library for embedding

## Verifying the Installation

Run the test suite to verify everything is working:

```bash
zig build test
```

## Building the Documentation

To build the documentation locally:

```bash
cd docs
mdbook serve --open
```

This will start a local server and open the documentation in your default web browser.

## Next Steps

- [Quick Start](./quick-start.md) - Get started with ZiggyDB
- [Building from Source](../development/building.md) - Advanced build options
