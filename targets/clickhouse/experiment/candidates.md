# Optimization Candidates — ClickHouse v25.8 LTS (v3, research-informed)

## Research Sources
- PR #39429: SortingAggregatedTransform buffered 100+ buckets, 52GB → 22GB
- PR #57074: Excessive Arena allocation during plan construction
- PR #59002: ArenaWithFreeLists never frees memory (replaced with new/delete for Keeper)
- Issue #32362: Fixed-block allocator proposal for hash tables
- Arena.h line 354: devs acknowledge quadratic waste, say "rethink approach"

## Confirmed Candidates (with targeted workloads)

### C1: Arena allocContinue quadratic copy waste
- **Files:** Arena.h:300-375
- **Profile evidence:** Arena = 56% of peak (512MB/907MB) in baseline profiling
- **Research evidence:** ClickHouse devs call it "hack-ish" and "quadratically wasteful" in source comments
- **Trigger condition:** Per-key aggregate state must exceed Arena chunk size, forcing allocContinue to copy and abandon old memory
- **Targeted workload:** `groupArray(toString(number))` with 1K keys × 100K string values per key (~10MB per key state, forces many realloc cycles)
- **Size calculation:** 1K keys × 100K values × ~20 bytes/string = ~2GB total state. Each key's array grows through multiple Arena chunks, triggering allocContinue ~10 times per key. Old chunks abandoned = ~1GB waste.
- **Status:** pending

### C2: Hash table resize double-buffer peak
- **Files:** HashTable.h:504-568
- **Profile evidence:** Hash table growth is part of the 56% Arena allocation
- **Research evidence:** Issue #32362 proposes fixed-block allocator to eliminate resize waste
- **Trigger condition:** High cardinality GROUP BY forces hash table through many resize cycles (256 → 4K → 64K → 1M → 16M cells)
- **Targeted workload:** `SELECT number, count() FROM numbers(10000000) GROUP BY number` (10M unique keys, forces 7+ resizes)
- **Size calculation:** Final table = 10M × ~40 bytes/cell = 400MB. During resize, old (400MB) + new (800MB) coexist = 1.2GB peak for 400MB of data.
- **Status:** pending

### C3: ArenaWithFreeLists never returns memory (power-of-2 waste)
- **Files:** ArenaWithFreeLists.h:60-111
- **Profile evidence:** Used by aggregate function states that are allocated/freed
- **Research evidence:** PR #59002 replaced it with new/delete for Keeper because it never frees
- **Trigger condition:** Many small allocations of non-power-of-2 sizes waste up to 50% per allocation
- **Targeted workload:** `uniqExact(key)` with 5M distinct string keys (allocates many variable-size state objects)
- **Status:** pending

## Workload Design Verification Checklist
- [ ] C1: Verify ArenaAllocChunks > 30 AND ArenaAllocBytes > 500MB on targeted workload
- [ ] C2: Verify hash table has > 5M entries (from system.query_log ProfileEvents)
- [ ] C3: Verify ArenaWithFreeLists is used (grep for usage in aggregate function path)
