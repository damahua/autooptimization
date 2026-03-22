# Optimization Hints: ClickHouse

## Known hot spots
- MergeTree storage engine allocates heavily during merges
- Column decompression buffers are not reused across queries
- The query pipeline creates many small temporary allocations

## Past attempts
- Jemalloc tuning helped in production, may be worth exploring
- LZ4 decompression is CPU-bound, consider streaming decompression

## Don't bother with
- Network layer — not a bottleneck for single-node
- Disk I/O — already optimized with direct I/O

## Architecture notes
- ClickHouse uses a columnar storage format (MergeTree)
- Queries are processed through a pipeline of Processors
- Memory allocations go through Common/Allocator
