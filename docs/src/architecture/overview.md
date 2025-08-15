# Architecture Overview

ZiggyDB is built with a modular architecture designed for performance, reliability, and simplicity. This document provides a high-level overview of the system's architecture.

## Core Components

### 1. Storage Engine
- **MemTable**: In-memory write buffer for recent writes
- **SSTables (Sorted String Tables)**: Immutable on-disk data files
- **Write-Ahead Log (WAL)**: Ensures durability of writes

### 2. Transaction Management
- **MVCC (Multi-Version Concurrency Control)**: Enables concurrent access
- **Transaction Manager**: Handles transaction lifecycle
- **Lock Manager**: Manages concurrent access to data

### 3. Query Processing
- **Query Parser**: Parses incoming queries
- **Query Optimizer**: Optimizes query execution plans
- **Execution Engine**: Executes queries against the storage engine

### 4. Utilities
- **Memory Management**: Custom allocators and memory pools
- **I/O Management**: Efficient file I/O operations
- **Concurrency Primitives**: Thread-safe data structures

## Data Flow

1. **Write Path**:
   - Writes first go to the Write-Ahead Log (WAL) for durability
   - Then they're added to the MemTable
   - When the MemTable reaches a threshold, it's flushed to disk as an SSTable

2. **Read Path**:
   - First checks the MemTable
   - Then checks the most recent SSTable
   - Continues checking older SSTables until the key is found or all are checked

3. **Compaction**:
   - Periodically merges SSTables to remove deleted/overwritten data
   - Improves read performance and reduces disk usage

## Concurrency Model

ZiggyDB uses a combination of:
- **MVCC** for read-write concurrency
- **Fine-grained locking** for internal data structures
- **Lock-free algorithms** where applicable
- **Async I/O** for non-blocking operations

## Next Steps

- [Storage Engine](./storage-engine.md) - Detailed storage architecture
- [Transaction Model](./transactions.md) - How transactions work in ZiggyDB
