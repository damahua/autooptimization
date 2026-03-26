# v4 Final Results — Framework Demonstration

## What the Framework Found

### Finding 1: Hash table resize cascade = 92% of memory allocations
- **Path:** `Allocator.cpp:178` (realloc) → `HashTable.h:539` (resize)
- **Evidence:** 571 of 633 memory trace samples (92%), 314.6 MB of 340.9 MB
- **Workload:** `SELECT toString(number) AS k, count() FROM numbers_mt(5000000) GROUP BY k`

### Finding 2: First-run penalty = 44% more peak memory than subsequent runs
- Run 1 (cold): 514.4 MB — hash table resizes from 256 to 5M entries
- Run 2+ (warm): 276-286 MB — pre-sized via HashTablesStatistics
- Existing optimization already handles subsequent runs
- First-run optimization needs query-plan cardinality hints

### Finding 3: Arena is NOT the bottleneck (confirmed with instrumentation)
- Arena: 98.6% efficient (11 MB waste / 767 MB allocated)
- Arena::realloc: 0 calls, Arena::allocContinue: 0 calls
- 100% of Arena is alignedAlloc (fixed-size aggregate state headers)

## Issues Filed
1. **#100775** — PODArray realloc peak during aggregate result materialization
   - Design proposal for `estimateResultBytes()` API
2. **#100838** — First-run GROUP BY hash table pre-sizing from source cardinality
   - 44% measured improvement, extends existing HashTablesStatistics

## Framework Pipeline Demonstrated
Phase 0: Used ClickHouse's own tests/performance/ suite (382 XML files)
Phase 1: RelWithDebInfo + system.trace_log → stack traces + custom Arena counters
Phase 2: Candidates from stack trace data (not code guessing)
Phase 2.75: Verified workload exercises the path (92% from one code path)
Phase 3: Multi-run N=3 for statistical comparison (0.09% variance with targeted workload)

## What Worked vs What Didn't

| Approach | Result |
|----------|--------|
| Code guessing (v1) | 62% "improvement" was build artifact |
| Arena free-list (v2) | 0% impact — Arena has 0 realloc calls |
| MemoryTracker fix (v4) | 0% impact — over-count resolves within function |
| **Stack-trace profiling** | Found real paths: HashTable resize (92%), PODArray realloc |
| **Cold vs warm comparison** | Found 44% first-run penalty — actionable finding |
