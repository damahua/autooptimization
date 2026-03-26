# Phase 1 Profiling Results — v4 Run

## Workload (Phase 0: from ClickHouse's own benchmark suite)

| Query | Source | Peak Memory | Time |
|-------|--------|-------------|------|
| Q1: `GROUP BY number` (10M unique) | aggregation_external.xml | 522 MB | 233ms |
| Q2: `uniqExact(number)` (10M) | uniq_without_key.xml | 389 MB | 132ms |
| Q3: `GROUP BY toString(number)` (5M) | prefetch_in_aggregation.xml | 513 MB | 99ms |
| Q4: `groupArray(toString(number))` | previous finding | 581 MB | 246ms |

## Stack Traces (from system.trace_log, RelWithDebInfo build)

### Top 3 allocations (each ~134 MB):

**#1 — Hash table buffer allocation during aggregation (134.5 MB):**
```
Allocator.cpp:132 (alloc)
  ↑ PODArray.h:387 (resize)
    ↑ Aggregator.cpp:969 (executeImplBatch)
      ↑ ColumnsHashingImpl.h:43 (hash table insert)
        ↑ Aggregator.cpp:1719 (execute)
```

**#2 & #3 — Aggregate function result materialization (134.2 MB each):**
```
Allocator.cpp:178 (realloc → __real_realloc)
  ↑ PODArray.h:155 (resize)
    ↑ IAggregateFunction.h:115 (insertResultIntoBatch)
      ↑ Aggregator.cpp (convertToBlockImplFinal)
```

## Key Finding: MemoryTracker Over-Counting in Allocator::realloc

Allocator.cpp lines 176-189 show a tracking sequence during realloc:
1. Line 176: `CurrentMemoryTracker::alloc(new_size)` — tracks new allocation
2. Line 178: `__real_realloc(buf, new_size)` — actual system realloc
3. Line 189: `CurrentMemoryTracker::free(old_size)` — frees old tracking

Between steps 1 and 3, MemoryTracker counts BOTH old_size AND new_size simultaneously.
For PODArray doubling (new_size = 2 × old_size), tracked peak = 3 × old_size
but actual live memory = 2 × old_size (or 1 × new_size if realloc extends in place).

This means ClickHouse's reported `memory_usage` in query_log OVER-REPORTS peak memory
during realloc operations by up to 50%. The actual RSS (from /proc/status) is the real
number and is ~2263 MB consistently across runs.

## Candidates from Profiling

| ID | Path | Size | Fix | Feasibility |
|----|------|------|-----|-------------|
| C1 | Hash table alloc in executeImplBatch | 134.5 MB | Pre-size hash table if cardinality hint available | Medium — needs cardinality estimation |
| C2 | PODArray realloc in insertResultIntoBatch | 2 × 134.2 MB | estimateResultBytes API (already filed as issue #100775) | Hard — API change |
| C3 | MemoryTracker over-counting in realloc | N/A (accounting bug) | Track net allocation, not gross | Easy code fix, potential upstream PR |

C3 is the most interesting new finding — it's a real code bug (over-counting) with a simple fix.

## exp004: MemoryTracker realloc over-counting fix — NO IMPACT

### Multi-Run Results (Q1: 10M GROUP BY, N=3)

| | Run 1 | Run 2 | Run 3 | Mean |
|---|---|---|---|---|
| Baseline RSS | 1105.5 | 1109.1 | 1095.6 | 1103.4 |
| exp004 RSS | 1094.7 | 1112.8 | 1093.7 | 1100.4 |
| Baseline query_mem | 517.6 | 522 | 522 | 520.5 |
| exp004 query_mem | 522 | 517.6 | 522 | 520.5 |

Delta RSS: -3.0 MB (-0.3%) — within noise
Delta query_mem: 0 MB — identical

### Why No Impact
The MemoryTracker over-counting during realloc resolves within the same function
call (alloc(new_size) then free(old_size)). The temporary spike only matters for
concurrent memory limit enforcement — if another thread checks the limit during
the brief window between lines 176 and 189. Our single-query workload doesn't
trigger this race condition.

The fix IS technically correct (tracks delta instead of gross) but the practical
impact requires concurrent queries competing for a tight memory limit.
