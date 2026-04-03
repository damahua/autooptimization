# Optimization Hints: chroma

## Architecture
- Chroma is a vector database: Python API server (uvicorn) + Rust core via PyO3/maturin
- Single-node mode: all-in-one process (API + indexing + storage)
- Rust crates: frontend, worker, index, blockstore, cache, segment, distance, types
- Uses jemalloc (tikv-jemallocator) with profiling support
- Vector index: HNSW (custom fork of hnswlib) + optional USearch
- Full-text: Tantivy
- Storage: Arrow-based blockstore, SQLite for metadata, optional S3/GCP

## Known hot spots (from research)
- HNSW index: all embeddings must reside in RAM; formula: max_collections ~ RAM_GB * 0.245
- Memory grows linearly with embedding count and dimension
- Concurrent queries degrade under load (100 concurrent → significant latency increase)
- Insert performance degrades as collection grows (inverted index traversal)
- Arrow blockstore serialization/deserialization during compaction
- Cache layer (LRU + partitioned locks) — potential lock contention under concurrent access

## Key Rust crates for memory
- rust/index/ — HNSW provider, full-text index, quantization
- rust/blockstore/ — Arrow-based block storage (serialization overhead)
- rust/cache/ — LRU cache with partitioned mutex
- rust/segment/ — data segmentation (memory layout)
- rust/distance/ — SIMD-accelerated distance computation (simsimd)
- rust/worker/ — query/compaction server (tokio async)

## Dependencies of note
- simsimd v6.5 — SIMD vector distance
- tantivy v0.22 — full-text search
- arrow v55.1 — columnar format
- parking_lot v0.12.3 — fast locks
- dashmap v6.1 — concurrent hashmap
- tokio v1.41 — async runtime

## Profiling strategy
1. jemalloc heap profiling (MALLOC_CONF=prof:true) → flamegraph via /debug/pprof/flamegraph
2. /proc/1/smaps for memory region breakdown
3. perf record -g for CPU profiling
4. Custom instrumentation if needed (add counters to suspected hot functions)
