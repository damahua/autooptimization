# Optimization Candidates — ClickHouse v25.8 LTS

## Confirmed (profile-validated hot paths)

| ID | Description | Files | Profile Evidence | Expected Impact | Status |
|----|-------------|-------|-----------------|-----------------|--------|
| C1 | Eliminate quadratic copy in Arena::allocContinue() — slab chain instead of copy | Arena.h:247-304 | Arena=512MB (56% of 907MB peak), 32 chunks, allocContinue is the growth path | HIGH | pending |
| C3 | Selective column mutation in Chunk::append() — mutate only written columns | Chunk.cpp:169-179 | ORDER BY=64MB (3.7% peak), append called per merge step | MEDIUM | pending |
| C7 | Pre-reserve chunks vector in MergeSortingTransform | SortingTransform.h:109 | ORDER BY=64MB, vector reallocs during sort | MEDIUM | pending |
| C9 | ArenaWithFreeLists — size-aware allocation to reduce internal fragmentation | ArenaWithFreeLists.h:40-84 | Total Arena=768MB across workload, free lists manage reuse patterns | MEDIUM | pending |

## Unconfirmed (not significant in profile)

| ID | Description | Files | Profile Evidence | Status |
|----|-------------|-------|-----------------|--------|
| C2 | Replace unordered_map with vector in MergeTreeReaderWide | MergeTreeReaderWide.h:112 | 12.5MB total (0.7% of peak) | skipped — reader caches negligible |
| C4 | Aligned realloc double-tracking | Allocator.cpp:199 | Can't isolate from current profiling | needs deeper profiling |
| C5 | Replace unordered_set prefetched_streams | MergeTreeReaderWide.h:115 | Part of 12.5MB reader path | skipped |
| C6 | Persist caches across readRows | MergeTreeReaderWide.cpp:206 | Part of 12.5MB reader path | skipped |
| C8 | Arena chunk metadata linked list | Arena.h:48 | 64 chunks × 40B = 2.5KB | skipped — negligible |
| C10 | Lazy buffer init in MergeTreeReaderStream | MergeTreeReaderStream.cpp:51 | Part of 12.5MB reader path | skipped |
| C11 | Cached buffer in HashTableGrower | HashTable.h:246 | CPU-only, no RSS impact | skipped |

## Key Insight from Profiling

**Arena is everything.** 56% of peak memory on the heaviest query (groupArray) is Arena allocation.
The MergeTree reader path we spent time on in v1 experiments (C2, C5, C6) accounts for only 0.7% of peak.
All confirmed candidates target Arena-related paths or sort buffer management.
