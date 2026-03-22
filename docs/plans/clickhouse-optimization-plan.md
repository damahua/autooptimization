# ClickHouse Optimization Plan

## Profiling Summary

**Environment**: ClickHouse 26.2.5.45 (official build), single-node, kind cluster
**Workload**: 100K-row MergeTree table, 5 analytical queries x 5 runs each
**Profiling method**: Built-in query_profiler (10ms sampling) + memory profiler (4MB step)

### Key Findings

1. **Memory is dominated by the write path**: 911 MB in WriteBufferFromFileDescriptor
   allocations, 103 MB in CompressedWriteBuffer, 64 MB in Block cloning during primary
   index serialization. These occur during INSERT and background merge operations.

2. **CPU is 99.8% idle**: Of 7,375 CPU samples, 7,357 are threads waiting in
   pthread_cond_wait/timedwait. The workload is too small and fast to show CPU hotspots.
   BackgroundSchedulePool (6,313 samples), MergeTreeBackgroundExecutor (362 samples),
   and AsynchronousInsertQueue (181 samples) dominate -- all idle threads.

3. **Per-query memory usage**: INSERT peaks at 11.6 MB, GROUP BY queries at 2.7 MB,
   time-series GROUP BY at 2.5 MB, filtered queries at 1.3 MB. All modest.

4. **ColumnSparse construction** allocates ~72 MB total via PODArray growth during
   MergeTree part reads and column creation.

5. **JIT sort compilation** in MergingSortedAlgorithm causes 2.7 MB string allocations
   during merge operations -- overhead with no benefit at this data scale.

### Optimization Priority

For peak RSS reduction with this workload profile, the highest-impact opportunities
are configuration-level tuning of buffer sizes, thread pool sizes, and caching behavior.
Source-level changes become important at larger data scales.

---

## Proposed Experiments

### Experiment 1: Reduce Write Buffer and Compression Buffer Sizes

**Branch**: `experiment/reduce-write-buffers`

**What to change**:
Add ClickHouse configuration overrides in `targets/clickhouse/config/memory_optimized.xml`:
```xml
<max_compress_block_size>262144</max_compress_block_size>    <!-- 256KB vs default 1MB -->
<min_compress_block_size>32768</min_compress_block_size>     <!-- 32KB vs default 64KB -->
```

These settings control the buffer sizes allocated by WriteBufferFromFileDescriptor
and CompressedWriteBuffer -- the #1 and #2 memory consumers at 911 MB and 103 MB
respectively.

**Expected impact**: 40-60% reduction in write-path memory. Peak RSS reduction of
50-200 MB depending on concurrent merge activity. Small potential increase in I/O
syscall frequency for very large writes.

**Workload queries exercising this path**: The INSERT query (numbers(100000)) and
any background merge triggered by the data load.

---

### Experiment 2: Reduce Background Thread Pool Sizes

**Branch**: `experiment/reduce-thread-pools`

**What to change**:
Add configuration in `targets/clickhouse/config/memory_optimized.xml`:
```xml
<background_pool_size>2</background_pool_size>              <!-- vs default 16 -->
<background_schedule_pool_size>4</background_schedule_pool_size>  <!-- vs default 128 -->
<background_merges_mutations_concurrency_ratio>1</background_merges_mutations_concurrency_ratio>
<max_threads>4</max_threads>
```

Profiling shows 6,313 idle samples in BackgroundSchedulePool threads and 362 in
MergeTreeBackgroundExecutor. Each idle thread consumes stack memory (~8MB per thread)
and the thread objects themselves hold state.

**Expected impact**: 20-40% reduction in baseline RSS. With 128 schedule pool threads
at ~8MB stack each, the default uses ~1GB just for stacks. Reducing to 4 saves ~1GB.
May slightly increase merge latency under heavy write load.

**Workload queries exercising this path**: All queries indirectly -- thread pools
are always running. The INSERT triggers merge scheduling.

---

### Experiment 3: Enable Mark Cache and Disable Sort JIT Compilation

**Branch**: `experiment/cache-and-jit-tuning`

**What to change**:
Add configuration:
```xml
<mark_cache_size>134217728</mark_cache_size>                 <!-- 128MB mark cache -->
<profiles>
    <default>
        <compile_sort_description>0</compile_sort_description>
        <min_count_to_compile_sort_description>999999</min_count_to_compile_sort_description>
    </default>
</profiles>
```

MergeTreeMarksLoader allocates 3.4 MB per load. With caching, marks are loaded once.
MergingSortedAlgorithm wastes 2.7 MB on JIT sort compilation that provides no benefit
at this data scale.

**Expected impact**: 5-10 MB reduction per query from avoiding JIT overhead. Mark cache
prevents repeated mark loading across queries on the same parts. Net RSS may increase
slightly due to cache itself but query memory usage decreases.

**Workload queries exercising this path**: All SELECT queries read marks. The ORDER BY
query and GROUP BY queries trigger sort merging. Background merges use MergingSortedAlgorithm.

---

### Experiment 4: Optimize ColumnSparse and Block Cloning in Write Path

**Branch**: `experiment/column-sparse-optimization`

**What to change**:
Source-level change in `src/Storages/MergeTree/MergeTreeDataPartWriterCompact.cpp`:

In `writeDataBlockPrimaryIndexAndSkipIndices()` (line 241), the code calls
`getIndexBlockAndPermute(block, ...)` which internally calls `Block::cloneEmpty()`
and allocates new columns for every granule batch. Instead, pre-allocate the primary
key block structure once and reuse it:

```cpp
// Before (current): allocates new Block every call
Block primary_key_block = getIndexBlockAndPermute(block, metadata_snapshot->getPrimaryKeyColumns(), nullptr);

// After: reuse pre-allocated structure, only copy data
if (!cached_primary_key_block)
    cached_primary_key_block = getIndexBlockAndPermute(block, metadata_snapshot->getPrimaryKeyColumns(), nullptr).cloneEmpty();
// ... populate from block without full clone
```

Also in `src/Columns/ColumnSparse.cpp`, the constructor creates a ColumnUInt64 via
`ColumnUInt64::create()` which starts with default PODArray capacity. For read paths
where the number of non-default values is known from metadata, pre-reserving would
avoid resize allocations.

**Expected impact**: 15-25% reduction in write-path allocations (~30 MB). Block cloning
currently accounts for 64 MB across 16 calls. Eliminating redundant clones saves most
of this. ColumnSparse optimization saves ~60 MB across 23 construction calls.

**Workload queries exercising this path**: INSERT query triggers writes. Background
merges exercise the compact writer. All SELECTs exercise ColumnSparse read path.

---

### Experiment 5: Tune Insert Squashing Parameters

**Branch**: `experiment/insert-squashing-tuning`

**What to change**:
Add configuration:
```xml
<profiles>
    <default>
        <min_insert_block_size_rows>65536</min_insert_block_size_rows>     <!-- vs default 1048449 -->
        <min_insert_block_size_bytes>16777216</min_insert_block_size_bytes> <!-- 16MB vs default 256MB -->
    </default>
</profiles>
```

The Squashing class (src/Interpreters/Squashing.h) merges small blocks into larger
ones before writing to MergeTree. The current defaults try to accumulate up to ~1M
rows or 256MB before flushing, which causes large column reservations (4.4MB seen
in profiling for ColumnVector<UInt64>::reserve during squash).

Smaller squash targets reduce peak memory at the cost of more, smaller parts
(which may trigger more merges later).

**Expected impact**: 10-20% reduction in INSERT peak memory. The INSERT currently
peaks at 11.6 MB; with smaller squash targets, this could drop to 6-8 MB. Trade-off:
more frequent writes to disk, potentially more background merges.

**Workload queries exercising this path**: The INSERT query directly. The
configuration affects the internal INSERT pipeline only.

---

## Experiment Execution Order

1. **Experiment 2** (thread pools) -- Largest expected RSS reduction, configuration-only
2. **Experiment 1** (write buffers) -- Second-largest impact, configuration-only
3. **Experiment 3** (cache + JIT) -- Low risk, configuration-only
4. **Experiment 4** (source changes) -- Requires source build, higher effort
5. **Experiment 5** (squashing) -- Moderate impact, simple config change

## Measurement Plan

For each experiment:
1. Deploy with `BUILD_MODE=stock` (experiments 1-3, 5) or `BUILD_MODE=source` (experiment 4)
2. Run identical workload: `./run.sh local workload.sh clickhouse`
3. Collect metrics:
   - `peak_rss_mb`: Primary metric (from `/proc/[pid]/status` VmHWM or `kubectl top pod`)
   - `latency_p99_ms`: Must not increase >10%
   - `throughput_qps`: Secondary metric
   - `error_rate`: Must remain 0
4. Compare against baseline (current profiling2 run)

## Baseline Metrics

- latency_p99_ms: 45
- latency_p50_ms: 31
- throughput_qps: 2.0
- error_rate: 0
- total_requests: 25
- INSERT peak_memory: 11.6 MB
- GROUP BY peak_memory: 2.7 MB
