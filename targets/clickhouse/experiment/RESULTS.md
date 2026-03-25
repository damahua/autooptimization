# ClickHouse v3 Experiment Results

## C1: Arena Free-List Recycling — NO IMPACT

### Multi-Run Results (targeted workload, N=3)

**Workload:** `groupArray(toString(number))` with 1K keys × 50K values (50M rows)

| | Run 1 | Run 2 | Run 3 | Mean | Stddev |
|---|---|---|---|---|---|
| **Baseline** | 2263.2 | 2264.3 | 2259.3 | **2262.3** | 2.1 |
| **Experiment** | 2264.2 | 2262.6 | 2257.8 | **2261.5** | 2.7 |

**Delta: -0.8 MB (-0.04%) — NO IMPACT**

### Why It Failed

`allocContinue` is NOT called by aggregate functions. It's called by **Column serialization** (ColumnString, ColumnArray, etc.) when writing data into Arena during hash table key storage.

`groupArray`'s internal array uses PODArray (system allocator), not Arena. Arena stores the hash table keys (strings) and fixed-size aggregate state headers, which don't trigger realloc.

The 768 MB of Arena allocation is from:
1. Hash table key storage (string keys stored via allocContinue)
2. Fixed-size aggregate state headers (allocated once, never realloced)

Neither of these paths benefits from the free-list because:
- Key storage via allocContinue abandons old memory in a DIFFERENT chunk (not the same chunk), so the free-list can't recycle it
- Fixed-size headers are never realloced

### Key Lesson

**Understanding the EXACT allocation path matters more than profiling aggregate metrics.** We knew Arena was 56% of peak memory, but didn't understand which Arena method (alloc vs allocContinue vs realloc) was responsible, or what data structures drive each path.

To properly target Arena waste, we need:
1. Instrumentation inside Arena (count calls to alloc vs allocContinue vs realloc)
2. Stack traces from trace_log showing which callers trigger allocContinue
3. Understanding of the Column → Arena interaction during hash table insertion

### Measurement Quality

The targeted workload produced **much more stable measurements** (stddev 2 MB, 0.09% variance) compared to the generic workload (stddev 77 MB, 17% variance). This confirms the framework improvement: targeted workloads give reliable results.
