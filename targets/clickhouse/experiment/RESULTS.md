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

## Instrumentation Results

### Arena Counter Data (from instrumented build)

Workload: `groupArray(toString(number))` with 1K keys × 50K values (50M rows)
Arena: 767 MB allocated, 756 MB used, 11 MB waste (1.4%)

| Method | Calls | Bytes | Significance |
|--------|-------|-------|-------------|
| **alignedAlloc** | **50,008,000** | **756 MB** | 100% of Arena usage |
| alloc | 0 | 0 | Never called |
| realloc | 0 | 0 | **NEVER CALLED — free-list target is dead code** |
| allocContinue | 0 | 0 | **NEVER CALLED — quadratic waste never occurs** |

### Conclusion

Arena is 98.6% efficient on this workload. There is no realloc or allocContinue waste to optimize. The 50M alignedAlloc calls are fixed-size aggregate state headers (one per hash table insert), which never need reallocation.

The 2204 MB peak memory comes from:
- Arena: 767 MB (35%) — aggregate state headers for 50M rows
- Remaining ~1437 MB — PODArray (system allocator) for groupArray internal arrays, hash table buffers, string data, column storage

### What This Means for Future Optimization

To reduce ClickHouse memory on aggregation workloads, the target should be:
1. **PODArray / system allocator** — where groupArray stores its actual arrays (~60% of peak)
2. **Hash table resize double-buffer** — where both old and new hash table coexist during resize
3. **NOT Arena** — Arena is already efficient (1.4% waste)

The ClickHouse devs' comment about "quadratic waste in allocContinue" is real but only triggers for specific code paths (ColumnString serialization, not aggregate functions). A workload that exercises ColumnString::serializeValueIntoArena would be needed to trigger it.

## BREAKTHROUGH: trace_log Stack Traces Identify Real Bottleneck

### Top 3 Allocations (each ~536 MB)

```
Allocator::realloc (Allocator.cpp:178)
  ↑ PODArrayBase::resize (PODArray.h:155)
    ↑ GroupArrayGeneralImpl<GroupArrayNodeString>::insertResultInto
      ↑ Aggregator::insertResultsIntoColumns
        ↑ Aggregator::convertToBlockImplFinal
          ↑ ConvertingAggregatedToChunksTransform::mergeSingleLevel
```

### What's Happening

The bottleneck is NOT during aggregation, but during **result materialization**:
1. `convertToBlockImplFinal` iterates all 1K groups
2. For each group, `insertResultInto` appends groupArray values to a result ColumnString
3. ColumnString's internal `chars` PODArray grows via `Allocator::realloc`
4. At ~536 MB, PODArray doubles to ~1 GB (2x growth factor)
5. During realloc, BOTH old (536 MB) and new (1 GB) buffers exist = **1.5 GB peak**

### The Optimization

Pre-reserve ColumnString's capacity before inserting results. The Aggregator knows the total result size (it can compute it from the aggregate states) but currently doesn't communicate this to the output column. Adding a `reserve()` call before the insert loop would avoid the realloc doubling peak.

### Evidence Quality
- Stack traces from ClickHouse's built-in trace_log (Memory trace type)
- Built with RelWithDebInfo for addressToLine/addressToSymbol
- 666 memory trace samples, top 3 all show same path
- Each allocation = 536 MB (PODArray doubling)

## exp002: Pre-reserve Output Columns — NO IMPACT

Baseline N=3: mean 2262.3 MB (stddev 2.1)
exp002 N=3: mean 2264.2 MB (stddev 0.3)
Delta: +1.9 MB (+0.08%) — zero effect

### Why
`IColumn::reserve(places.size())` only reserves the offsets array (1000 × 8B = 8KB).
The 536 MB allocation is in ColumnString's `chars` PODArray (actual string bytes).
`ColumnString::reserve(n)` only does `offsets.reserve_exact(n)` — it doesn't touch `chars`.

### What Would Work
Need to pre-reserve `chars` with the total byte count. Options:
1. Add `ColumnString::reserveChars(size_t total_bytes)` — simple but needs total byte count
2. Compute total bytes from aggregate states before materializing — requires iterating states twice
3. Change groupArray to track cumulative byte count during aggregation and expose it

The fix is feasible but requires touching ColumnString + groupArray aggregate function code.
