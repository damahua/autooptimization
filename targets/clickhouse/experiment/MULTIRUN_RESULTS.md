# Multi-Run Benchmark Results — Arena Free-List

## Verdict: NO MEASURABLE IMPROVEMENT

The single-run result (-7.8% RSS) was **noise**. Multi-run benchmarking (N=5 each) shows the distributions completely overlap.

## Data

### Baseline (unmodified v25.8 LTS, N=5)

| Run | peak_rss_mb | current_rss_mb |
|-----|-------------|----------------|
| 1 | 1334.7 | 1106.7 |
| 2 | 1269.5 | 1046.5 |
| 3 | 1344.3 | 1145.2 |
| 4 | 1212.7 | 1017.4 |
| 5 | 1441.8 | 1115.5 |

**Mean: 1320.6 MB, Stddev: 77.1 MB, Range: 229.1 MB**

### Experiment (Arena free-list, N=5)

| Run | peak_rss_mb | current_rss_mb |
|-----|-------------|----------------|
| 1 | 1288.4 | 1086.3 |
| 2 | 1440.0 | 1093.4 |
| 3 | 1335.7 | 1069.5 |
| 4 | 1269.4 | 1032.6 |
| 5 | 1270.8 | 1044.4 |

**Mean: 1320.9 MB, Stddev: 64.2 MB, Range: 170.6 MB**

### Comparison

| Metric | Baseline | Experiment | Delta |
|--------|----------|------------|-------|
| Mean peak_rss_mb | 1320.6 | 1320.9 | **+0.3 (+0.02%)** |
| Stddev | 77.1 | 64.2 | - |
| Range | 1212.7 – 1441.8 | 1269.4 – 1440.0 | overlapping |

## Why the Single-Run Was Wrong

- Run-to-run RSS variance is ~230 MB (17% of mean)
- The "134 MB improvement" from the single run falls entirely within this natural variance
- Process RSS is affected by: jemalloc internal state, kernel memory decisions, background ClickHouse processes, timing of page faults

## Why the Free-List Didn't Help

Our workload produces aggregate states of ~400 bytes per key (50 values × 8 bytes per Float64). These are too small to trigger meaningful Arena::realloc waste:
- Small allocations fit within Arena chunks without needing realloc
- When realloc does occur, the old region is <1KB — recycling it saves negligible RSS
- The dominant RSS consumer is Arena chunk allocation (512 MB across 32 exponentially growing chunks), not realloc waste within chunks

## ClickHouse PR Status

PR #100672 was closed with this data and an honest explanation.

## Lessons

1. **Never report single-run performance results** — RSS variance is 17% on this workload
2. **Profile the mechanism, not just the outcome** — we should have instrumented how many times `allocFromFreeList` returned non-null
3. **Match optimization to allocation pattern** — 400-byte aggregate states don't produce meaningful realloc waste; the free-list targets a pattern that doesn't occur at this scale
4. **The framework's multi-run capability needs to be built in** — it shouldn't be an afterthought
