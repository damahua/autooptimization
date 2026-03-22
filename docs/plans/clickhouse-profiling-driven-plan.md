# ClickHouse Profiling-Driven Optimization Plan (profiling3)

## Profiling Data Collection

**Date**: 2026-03-22
**Environment**: ClickHouse latest (official stock image), single-node, kind cluster "autoopt"
**Resources**: 2 CPU, 2Gi memory limit, 1Gi memory request
**Workload**: 100K-row MergeTree table (`test_data`), 5 analytical queries x 5 runs each
**Profiling method**: Built-in query_profiler (10ms sampling) + memory profiler (4MB step via `total_memory_profiler_step=4194304`)
**Image tag**: profiling3
**Build mode**: stock

### Baseline Metrics

- latency_p99_ms: 41
- latency_p50_ms: 33
- throughput_qps: 2.0
- error_rate: 0
- total_requests: 25

### Workload Queries

1. `SELECT category, avg(value), max(value), min(value) FROM test_data GROUP BY category`
2. `SELECT toStartOfHour(timestamp) AS hour, count(), avg(value) FROM test_data GROUP BY hour ORDER BY hour`
3. `SELECT category, quantile(0.99)(value) FROM test_data GROUP BY category`
4. `SELECT * FROM test_data WHERE value > 90 ORDER BY timestamp LIMIT 100`
5. `SELECT category, count(), sum(value) FROM test_data WHERE timestamp > '2024-06-01' GROUP BY category`

Each query run 5 times. Plus initial INSERT of 100K rows.

---

## Section A: Memory Allocation Hot Paths Analysis

### Raw Data

Total memory traced: 310,406,671 bytes (~296 MB)

Allocation size distribution:
- 1MB-16MB bucket: 71 allocations, 310,406,495 bytes (99.99%)
- <1KB bucket: 3 allocations, 176 bytes (0.00%)

**Key finding**: Nearly ALL allocations are large (1MB-16MB). This is consistent with ClickHouse's columnar write path which allocates entire column buffers at once.

### Top 5 Allocation Hot Paths (with call chains)

**1. SystemLog<PartLogElement>::savingThreadFunction() -- 52.5 MB (4 traces)**
```
SystemLog<PartLogElement>::savingThreadFunction()
  -> PipelineExecutor::executeStep()
    -> ExecutionThreadContext::executeTask()
      -> ExceptionKeepingTransform::work()
        -> SinkToStorage::onConsume()
          -> MergeTreeSink::consume()
            -> MergeTreeDataWriter::writeTempPartImpl()
              -> MergedBlockOutputStream::MergedBlockOutputStream()
                -> Memory<Allocator<false,false>>::alloc()
```
**What it does**: ClickHouse's internal system logging (part_log) writes log entries as MergeTree parts. Each flush allocates column buffers for the part write via Memory<Allocator>::alloc(). These are multi-megabyte allocations for write buffers during the part write.

**Why it allocates**: The MergedBlockOutputStream constructor pre-allocates compression buffers and column write buffers. Each column gets its own write buffer. With system tables having many columns, this multiplies.

**2. SystemLog<TextLogElement>::savingThreadFunction() -- 52.4 MB (4 traces)**
Same call chain as #1 but for the text_log system table. Text log entries are written more frequently (logging from all queries), so multiple flush cycles each allocate full write buffer sets.

**3. SystemLog<MetricLogElement>::savingThreadFunction() -- 36.2 MB (2 traces)**
Same pattern for metric_log. Metric log captures server metrics periodically.

**4. SystemLog<TraceLogElement>::savingThreadFunction() -- 35.0 MB (2 traces)**
Same pattern for trace_log. Since profiling is enabled, the trace log captures profiling samples, creating a feedback loop where profiling itself generates allocations.

**5. SystemLog<AsynchronousMetricLogElement>::savingThreadFunction() -- 26.1 MB (2 traces)**
Same pattern for asynchronous_metric_log.

### Non-SystemLog Allocation Hot Paths

**6. ExecutionThreadContext::executeTask() (user workload) -- 40.4 MB (5 traces)**
These are MergeTree write allocations from the INSERT statement and background merges.

**7. ColumnString::indexImpl<unsigned long> -- 4.6 MB (1 trace)**
```
MergeTreeSink::consume()
  -> MergeTreeDataPartWriterCompact::write()
    -> permuteBlockIfNeeded()
      -> ColumnString::indexImpl<unsigned long>()
        -> Allocator<false,false>::alloc()
```
String column reindexing during part writes. Allocates a new buffer to permute string data by sort key order.

**8. ApplySquashingTransform::onConsume() -- 4.4 MB (2 traces)**
```
ApplySquashingTransform::onConsume()
  -> ColumnVector<unsigned long>::reserve()
```
The squashing transform accumulates small blocks into larger ones before writing. Calls `reserve()` on column vectors, triggering PODArray growth.

**9. AggregatingTransform::work() -- 1.5 MB (1 trace)**
Hash table allocations during GROUP BY aggregation. Uses operator new for hash table buckets.

**10. HTTPHandler::processQuery() -- 1.0 MB (1 trace)**
HTTP handler allocates buffers for query processing (request/response handling).

---

## Section B: CPU Hot Paths Analysis

**Key finding**: CPU profiling shows 100% idle threads. All top samples are in pthread_cond_wait/timedwait. The workload (100K rows, 25 queries) completes too fast to register in 10ms CPU sampling.

Top CPU consumers (all idle/waiting):

| Samples | Function | Caller |
|---------|----------|--------|
| 2,081 | pthread_cond_wait | BackgroundSchedulePool::threadFunction() |
| 121 | pthread_cond_wait | MergeTreeBackgroundExecutor<RoundRobinRuntimeQueue>::threadFunction() |
| 69 | pthread_cond_timedwait | condition_variable::wait_until() |
| 60 | pthread_cond_timedwait | AsynchronousInsertQueue thread |
| 57 | pthread_cond_wait | MergeTreeBackgroundExecutor<DynamicRuntimeQueue>::threadFunction() |
| 4 | __read | ReadBufferFromFileDescriptor::readImpl() (TraceCollector) |
| 1 | __poll | SocketImpl::pollImpl() (HTTPServerConnection) |

**Only 5 non-idle CPU samples** out of 2,462+ total. CPU optimization is not actionable with this workload size.

---

## Section C: Per-Query Resource Usage

| Peak Memory | Read Bytes | Read Rows | Duration (ms) | Query |
|------------|------------|-----------|---------------|-------|
| 11.6 MB | 800 KB | 100,000 | 14 | INSERT INTO test_data SELECT ... FROM numbers(100000) |
| 5.4 MB | 16 B | 1 | 1 | SELECT count() FROM test_data |
| 2.7 MB | 1.2 MB | 100,000 | 2-15 | GROUP BY category (avg/max/min) |
| 2.7 MB | 1.2 MB | 100,000 | 3-4 | quantile(0.99) GROUP BY category |
| 2.5 MB | 1.2 MB | 100,000 | 2-9 | toStartOfHour GROUP BY hour |
| 1.3 MB | 0-131 KB | 0-32,768 | 2-3 | WHERE timestamp > '2024-06-01' GROUP BY category |

**Key findings**:
- INSERT is the most memory-intensive query at 11.6 MB
- GROUP BY queries use 2.5-2.7 MB -- consistent across runs
- The filtered query (WHERE timestamp > '2024-06-01') benefits from partition pruning (0 read_bytes on subsequent runs), drops to 1.3 MB
- `SELECT count()` somehow uses 5.4 MB despite reading only 16 bytes -- likely metadata/index loading overhead

---

## Section D: Server Memory State

### Memory Overview

| Metric | Value | Notes |
|--------|-------|-------|
| RSS (MemoryResident) | 1,497 MB | Actual process memory |
| jemalloc.mapped | 1,267 MB | Virtual memory mapped by jemalloc |
| jemalloc.resident | 1,247 MB | Physical pages held by jemalloc |
| jemalloc.active | 1,070 MB | Active allocations |
| jemalloc.allocated | 909 MB | Bytes actively used by application |
| jemalloc.retained | 504 MB | Memory retained (not returned to OS) |
| jemalloc.metadata | 65 MB | jemalloc internal metadata |
| MemoryTracking | 713 MB | ClickHouse tracked allocations |
| MemoryCode | 380 MB | Code segment (read-only, not optimizable) |

**Key finding -- jemalloc fragmentation/retention**:
- jemalloc.allocated (909 MB) - jemalloc.active (1,070 MB) = 161 MB internal fragmentation
- jemalloc.retained = 504 MB not returned to OS
- RSS (1,497 MB) - jemalloc.resident (1,247 MB) = 250 MB from non-jemalloc sources (code, shared libs, kernel)
- MemoryTracking (713 MB) < jemalloc.allocated (909 MB): ~196 MB untracked by ClickHouse

### Cache Configuration vs Usage

| Cache | Configured Size | Actual Usage | Waste |
|-------|----------------|--------------|-------|
| mark_cache | 512 MB | 1,592 B | 99.9997% unused |
| uncompressed_cache | 128 MB | 0 B | 100% unused |
| index_mark_cache | 5,120 MB (5 GB!) | 0 B | 100% unused |
| compiled_expression_cache | 128 MB | 32 KB | 99.97% unused |

**CRITICAL FINDING**: `index_mark_cache_size` defaults to 5,368,709,120 bytes (5 GB). While ClickHouse uses lazy allocation (doesn't pre-allocate), this setting affects `max_server_memory_usage` calculation. The mark_cache at 512 MB (already reduced from 5 GB default by our config) holds only 1.6 KB of actual data.

### Background Pool Sizing

| Pool | Configured Threads |
|------|-------------------|
| background_schedule_pool_size | 512 |
| background_pool_size | 16 |
| background_fetches_pool_size | 16 |
| background_distributed_schedule_pool_size | 16 |
| background_buffer_flush_schedule_pool_size | 16 |
| background_message_broker_schedule_pool_size | 16 |
| background_common_pool_size | 8 |
| background_move_pool_size | 8 |
| max_thread_pool_size | 10,000 |

**Key finding**: `background_schedule_pool_size=512` is extremely oversized for single-node with one small table. Each thread uses 8 MB stack = potential ~4 GB of stack memory. The CPU profiling confirms: 2,081 idle samples in BackgroundSchedulePool alone.

---

## Section E: Allocation Patterns (Pooling Candidates)

**Section E returned empty results**. The memory profiler's 4 MB sampling step is too coarse to capture the alloc/dealloc churn pattern. With `total_memory_profiler_step=4194304`, only allocations crossing a 4 MB boundary get traced. Small allocations that churn frequently are invisible.

This is consistent with Section A showing only 1MB-16MB allocations: the profiler only captures when the accumulated allocation counter crosses the 4 MB threshold, so it captures large allocations but misses small churn.

**Implication**: To detect alloc/free churn, we would need to reduce `total_memory_profiler_step` to a smaller value (e.g., 65536 = 64 KB). However, this would significantly slow down the server. For now, we focus on the large-allocation patterns visible in Section A.

---

## Step 5: Source Code Analysis of Hot Functions

### Hot Function 1: Memory<Allocator<false,false>>::alloc()

**File**: `src/Common/PODArray.h:132-142`
```cpp
void alloc(size_t bytes, TAllocatorParams &&... allocator_params)
{
    char * allocated = reinterpret_cast<char *>(TAllocator::alloc(bytes, ...));
    c_start = allocated + pad_left;
    c_end = c_start;
    c_end_of_storage = allocated + bytes - pad_right;
    ...
}
```
This is the underlying allocation for PODArray (ClickHouse's main vector-like container). Called when creating column data buffers during MergeTree part writes. Each column in a part write gets its own PODArray allocation.

### Hot Function 2: MergeTreeSink::consume()

**File**: `src/Storages/MergeTree/MergeTreeSink.cpp:90`
The MergeTree write pipeline entry point. Called once per block by the INSERT pipeline and by each SystemLog flush. Calls `writeTempPart()` -> `writeTempPartImpl()` -> `MergedBlockOutputStream()` which allocates all the compression and column buffers.

### Hot Function 3: Allocator<false,false>::alloc()

**File**: `src/Common/Allocator.cpp:136-140`
```cpp
void * Allocator<clear_memory_, populate>::alloc(size_t size, size_t alignment)
{
    checkSize(size);
    return allocImpl<clear_memory_, populate>(size, alignment);
}
```
This calls `CurrentMemoryTracker::alloc(size)` first (accounting), then `__real_malloc(size)`. It's the common allocator for all ClickHouse memory. Hot because it's called by PODArray, HashTable, and all column types.

---

## Step 6: Classification of Optimization Opportunities

| # | Hot Path | Pattern | Classification | Impact |
|---|----------|---------|---------------|--------|
| 1 | SystemLog write allocations (52 MB x 5 logs = ~200 MB) | Config oversizing | System logs flush too frequently, each flush allocates full MergeTree write buffers | HIGH |
| 2 | background_schedule_pool_size=512 | Config oversizing | 512 threads for single-node with 1 table; mostly idle | HIGH |
| 3 | index_mark_cache_size=5 GB | Config oversizing | Default 5 GB, 0 bytes used | MEDIUM |
| 4 | mark_cache_size=512 MB | Config oversizing | 512 MB configured, 1.6 KB used | MEDIUM |
| 5 | jemalloc.retained=504 MB | Config oversizing | jemalloc not returning memory to OS | HIGH |
| 6 | ColumnString::indexImpl realloc (4.6 MB) | Unnecessary copy | Full string column copied during permutation | LOW |
| 7 | ApplySquashingTransform reserve (4.4 MB) | Oversized buffer | Column vectors reserve for squashing | LOW |
| 8 | AggregatingTransform hash table (1.5 MB) | Normal operation | Hash table growth during GROUP BY | LOW |

---

## Step 7: Experiment Plan

### Recommended Experiment Order

Ordered by expected impact and risk (configuration changes first, then source changes):

---

### Experiment 1: Aggressive jemalloc Tuning

**Branch**: `autoopt/clickhouse/profiling3-exp001`

**What to change**: Add jemalloc tuning in `targets/clickhouse/config/memory_optimized.xml`:
```xml
<jemalloc>
    <dirty_decay_ms>1000</dirty_decay_ms>     <!-- default 5000; return dirty pages faster -->
    <muzzy_decay_ms>1000</muzzy_decay_ms>     <!-- default 10000; return muzzy pages faster -->
</jemalloc>
```

**Why (from profiling data)**:
- jemalloc.retained = 504 MB (memory not returned to OS)
- jemalloc.active (1,070 MB) - jemalloc.allocated (909 MB) = 161 MB internal fragmentation
- jemalloc.arenas.dirty_decay_ms is currently 5000
- Faster decay should reduce RSS by releasing unused pages sooner

**Workload queries**: All queries benefit; jemalloc manages all allocations.

**Expected impact**: 100-300 MB RSS reduction from faster page return.

**Risks**: Slightly higher CPU from more frequent page purging. Minimal impact expected with this small workload.

---

### Experiment 2: Reduce Background Thread Pool Sizes

**Branch**: `autoopt/clickhouse/profiling3-exp002`

**What to change**: Add to `targets/clickhouse/config/memory_optimized.xml`:
```xml
<background_schedule_pool_size>16</background_schedule_pool_size>  <!-- from 512 -->
<background_pool_size>2</background_pool_size>                      <!-- from 16 -->
<background_common_pool_size>2</background_common_pool_size>        <!-- from 8 -->
<background_fetches_pool_size>2</background_fetches_pool_size>      <!-- from 16 -->
<background_move_pool_size>2</background_move_pool_size>            <!-- from 8 -->
<background_distributed_schedule_pool_size>2</background_distributed_schedule_pool_size>  <!-- from 16 -->
<background_buffer_flush_schedule_pool_size>2</background_buffer_flush_schedule_pool_size>  <!-- from 16 -->
<background_message_broker_schedule_pool_size>2</background_message_broker_schedule_pool_size>  <!-- from 16 -->
<max_thread_pool_size>100</max_thread_pool_size>                    <!-- from 10000 -->
```

**Why (from profiling data)**:
- CPU profiling: 2,081 samples in BackgroundSchedulePool idle wait, 121 in MergeTreeBackgroundExecutor idle wait, 57 in DynamicRuntimeQueue idle wait
- background_schedule_pool_size=512 threads, each with 8 MB stack = up to 4 GB just for stacks
- Single-node with one small table needs at most 2-4 background threads

**Workload queries**: INSERT triggers background merges via background_pool. All other pools are unnecessary for this workload.

**Expected impact**: 200-500 MB RSS reduction from eliminating idle thread stacks. The 512-thread schedule pool alone can waste gigabytes.

**Risks**: If too few merge threads, INSERT-heavy workloads may queue. With 100K rows and one table, 2 threads is more than sufficient.

---

### Experiment 3: Reduce Cache Sizes

**Branch**: `autoopt/clickhouse/profiling3-exp003`

**What to change**: Update `targets/clickhouse/config/memory_optimized.xml`:
```xml
<mark_cache_size>8388608</mark_cache_size>                   <!-- 8 MB (from 512 MB); only 1.6 KB used -->
<uncompressed_cache_size>0</uncompressed_cache_size>          <!-- disabled (from 128 MB); 0 bytes used -->
<index_mark_cache_size>8388608</index_mark_cache_size>        <!-- 8 MB (from 5 GB default); 0 bytes used -->
<compiled_expression_cache_size>8388608</compiled_expression_cache_size>  <!-- 8 MB (from 128 MB); 32 KB used -->
```

**Why (from profiling data)**:
- mark_cache: 512 MB configured, 1,592 bytes used (0.0003% utilization)
- uncompressed_cache: 128 MB configured, 0 bytes used
- index_mark_cache: 5 GB default (!), 0 bytes used
- compiled_expression_cache: 128 MB configured, 32 KB used
- While ClickHouse uses lazy allocation for caches, the `max_server_memory_usage` is calculated as 90% of total memory minus these cache sizes, so oversized cache configs can affect memory management decisions

**Workload queries**: All SELECT queries use mark_cache for reading MergeTree index marks. No queries use uncompressed_cache (data is small enough to not need it).

**Expected impact**: Direct RSS impact may be small (caches are lazily allocated), but reducing max_server_memory_usage calculation overhead and preventing future cache growth is important for tight memory environments. Estimated 10-50 MB improvement.

**Risks**: If workload grows to millions of rows with many parts, small mark_cache could cause more disk I/O. Acceptable for this workload.

---

### Experiment 4: Reduce SystemLog Overhead

**Branch**: `autoopt/clickhouse/profiling3-exp004`

**What to change**: Add to `targets/clickhouse/config/memory_optimized.xml`:
```xml
<metric_log remove="1"/>
<asynchronous_metric_log remove="1"/>
<part_log remove="1"/>
<text_log remove="1"/>
<processor_profile_log remove="1"/>
<!-- Keep query_log and trace_log for profiling -->
```

**Why (from profiling data)**:
- SystemLog write paths account for ~200 MB of the ~296 MB total traced allocations (68%)
  - PartLogElement: 52.5 MB
  - TextLogElement: 52.4 MB
  - MetricLogElement: 36.2 MB
  - TraceLogElement: 35.0 MB
  - AsynchronousMetricLogElement: 26.1 MB
  - QueryLogElement: 23.2 MB
  - ProcessorProfileLogElement: 17.5 MB
- Each SystemLog flush writes a MergeTree part, allocating full column buffers
- These system logs are not needed for a memory optimization workload

**Workload queries**: No user queries use these logs. Disabling them eliminates background allocation overhead.

**Expected impact**: 100-200 MB RSS reduction. SystemLog writes are the #1 source of memory allocations in profiling. Eliminating 5 of 7 system logs should cut allocation volume by ~60%.

**Risks**: Loss of diagnostic data. We keep query_log and trace_log for profiling. For production, logs would need to be re-enabled.

---

### Experiment 5: Combined Configuration Optimization

**Branch**: `autoopt/clickhouse/profiling3-exp005`

**What to change**: Combine the most effective changes from experiments 1-4 into a single configuration:

```xml
<clickhouse>
    <!-- jemalloc tuning -->
    <jemalloc>
        <dirty_decay_ms>1000</dirty_decay_ms>
        <muzzy_decay_ms>1000</muzzy_decay_ms>
    </jemalloc>

    <!-- Thread pool reduction -->
    <background_schedule_pool_size>16</background_schedule_pool_size>
    <background_pool_size>2</background_pool_size>
    <background_common_pool_size>2</background_common_pool_size>
    <background_fetches_pool_size>2</background_fetches_pool_size>
    <background_move_pool_size>2</background_move_pool_size>
    <background_distributed_schedule_pool_size>2</background_distributed_schedule_pool_size>
    <background_buffer_flush_schedule_pool_size>2</background_buffer_flush_schedule_pool_size>
    <background_message_broker_schedule_pool_size>2</background_message_broker_schedule_pool_size>
    <max_thread_pool_size>100</max_thread_pool_size>

    <!-- Cache reduction -->
    <mark_cache_size>8388608</mark_cache_size>
    <uncompressed_cache_size>0</uncompressed_cache_size>
    <index_mark_cache_size>8388608</index_mark_cache_size>
    <compiled_expression_cache_size>8388608</compiled_expression_cache_size>

    <!-- Disable unnecessary system logs -->
    <metric_log remove="1"/>
    <asynchronous_metric_log remove="1"/>
    <part_log remove="1"/>
    <text_log remove="1"/>
    <processor_profile_log remove="1"/>
</clickhouse>
```

**Why**: After validating individual experiments, combine for maximum impact.

**Expected impact**: 300-700 MB RSS reduction from combined effects.

---

### Experiment 6: Source-Level Optimization -- Write Buffer Sizing

**Branch**: `autoopt/clickhouse/profiling3-exp006`

**What to change**: Configuration to reduce write buffer sizes:
```xml
<profiles>
    <default>
        <max_compress_block_size>262144</max_compress_block_size>    <!-- 256 KB from 1 MB -->
        <min_compress_block_size>32768</min_compress_block_size>     <!-- 32 KB from 64 KB -->
        <min_insert_block_size_rows>65536</min_insert_block_size_rows>  <!-- from 1048449 -->
        <min_insert_block_size_bytes>16777216</min_insert_block_size_bytes>  <!-- 16 MB from 256 MB -->
    </default>
</profiles>
```

**Why (from profiling data)**:
- All 71 large allocations (1-16 MB range) come from the write path
- MergedBlockOutputStream allocates compression buffers sized by `max_compress_block_size`
- Smaller blocks = smaller per-allocation size = less peak memory

**Workload queries**: INSERT and all SystemLog flushes (which write MergeTree parts).

**Expected impact**: 20-40% reduction in per-write allocation size. Combined with fewer SystemLog writes from Experiment 4, this compounds.

**Risks**: More I/O operations for large data writes. Acceptable for 100K rows.

---

## Limitations and Notes

1. **Workload is small**: 100K rows is far below production scale (typically millions to billions). Memory optimization results may not transfer to large-scale workloads.

2. **CPU profiling is not actionable**: The workload completes too fast for 10ms CPU sampling. To get useful CPU data, either:
   - Increase workload to 10M+ rows with more complex queries
   - Reduce sampling interval (risks overhead)
   - Use perf/bpf tools instead of ClickHouse's built-in profiler

3. **Memory profiler step is coarse**: `total_memory_profiler_step=4194304` (4 MB) means only allocations that cross a 4 MB boundary are captured. Small allocations (hash tables, strings, temporaries) are invisible. This is why Section E (alloc/free churn) returned empty.

4. **SystemLog overhead dominates**: 68% of traced allocations come from ClickHouse's own system logging, not user queries. In production, system logs are valuable. Our optimization of disabling them is specific to this memory-optimization context.

5. **Stock image limitation**: We're using the official ClickHouse image (BUILD_MODE=stock). Source-level changes require switching to BUILD_MODE=source with an incremental build setup.

6. **jemalloc retention**: The 504 MB of retained memory may not all be recoverable -- some is necessary for jemalloc's internal bookkeeping and page alignment.
