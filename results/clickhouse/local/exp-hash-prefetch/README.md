# exp-hash-prefetch: Enable hash table prefetching for string GROUP BY (-8% latency)

## Hypothesis
ClickHouse prefetches hash table buckets during GROUP BY for numeric keys
(`has_cheap_key_calculation=true`) but skips string keys. The adaptive
`PrefetchingHelper` should handle string hash methods correctly since it
measures actual iteration latency — the guard is unnecessarily conservative.

Profile evidence: `HashTable::resize` = 265 MB (64 calls) and
`StringHashTable::alloc` = 381 MB during high-cardinality string GROUP BY.
CPU is bound by hash table lookups with cache misses on the large (500K key) table.

Addresses ClickHouse issue #95631.

## Code changes (diff.patch)
3 files, ~25 lines:
1. `src/Interpreters/Aggregator.cpp` — remove `has_cheap_key_calculation` guard (3 locations)
2. `src/Common/HashTable/StringHashTable.h` — add `PrefetchCallable`, `prefetch()`, `reserve()`, `prefetchByHash()` no-op
3. `src/Common/HashTable/TwoLevelStringHashTable.h` — add forwarding `prefetch()` + `reserve()`-based constructor

## How to reproduce
1. `./build.sh`     — apply patch + build from source (~2 min incremental)
2. `./deploy.sh`    — deploy to Kind cluster
3. `./workload.sh`  — load 10M rows + benchmark (same workload as baseline)
4. `./collect.sh`   — collect metrics
5. `./teardown.sh`  — clean up

Compare results against `../baseline/` — run both back-to-back.

## Expected results
- GROUP BY latency (500K string keys): ~125ms median (baseline ~136ms)
- Improvement: ~8% latency reduction
- Regression on 1K/100K keys: neutral (no slowdown)

## Actual results (10 runs)
Run 1: 130ms, Run 2: 130ms, Run 3: 125ms, Run 4: 125ms, Run 5: 126ms
Run 6: 125ms, Run 7: 125ms, Run 8: 126ms, Run 9: 125ms, Run 10: 125ms
Median: 125ms (range: 125-130ms)

Decision: **KEEP** — 8.1% improvement, distributions don't overlap
PR: https://github.com/ClickHouse/ClickHouse/pull/101007
