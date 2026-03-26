# autooptimization

Autonomous AI-driven code optimization framework. Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).

## Prerequisites

Required tools: docker, kubectl, kind, git, envsubst (from gettext), bc, curl

## Setup

1. **Agree on target, environment, metric, and tag**
2. **Read target config:** `targets/<target>/target.md`, `targets/<target>/hints.md`
3. **Clone target source** (shallow, selective submodules for large C++ projects)
4. **Verify environment:** docker, kubectl, kind cluster
5. **Initialize results:**
   ```bash
   mkdir -p "results/<target>/<env>/logs" "results/<target>/<env>/profiles"
   ```

## Phase 1: Deep Profile — Find the Real Bottleneck

**This is the most important phase.** Do NOT scan code or guess optimizations. Profile FIRST with stack-level allocation tracing to find WHERE resources are actually spent.

### 1a. Build with Debug Symbols

Build with `RelWithDebInfo` (or equivalent) so profiling tools can resolve function names and source locations. Without symbols, profiling data is useless.

```
-DCMAKE_BUILD_TYPE=RelWithDebInfo  # not Release
```

### 1b. Deploy and Run Representative Workload

The workload should stress the primary metric (e.g., peak_rss_mb for memory, latency for CPU). Use production-representative data sizes, not toy data.

### 1c. Collect Stack-Level Allocation Traces

**Use the target's built-in profiling tools first.** Examples:
- **ClickHouse:** `system.trace_log` with `trace_type='Memory'`, `memory_profiler_step=1048576`
- **Go:** `pprof` heap profile via HTTP endpoint
- **Python:** `tracemalloc` with stack traces
- **Generic C/C++:** `heaptrack`, `jemalloc prof` (`MALLOC_CONF=prof:true`), or `valgrind --tool=massif`

**If no built-in tools exist**, use:
- `/proc/PID/smaps` for memory region breakdown (coarse)
- `perf record -g` for CPU flame graphs

### 1d. Identify the EXACT Allocation Path

From the traces, answer:
- **Which function** allocates the most bytes? (not "which module" — the FUNCTION)
- **What call stack** leads to it? (at least 5 frames deep)
- **What data structure** is growing? (PODArray, Arena, std::vector, hash table buffer?)
- **How much** does it allocate? (absolute bytes, % of total)
- **WHY** is it allocating? (realloc doubling, new element insertion, copy-on-write, serialization?)

**Output:** Write `profiles/baseline-stacks.txt` with the top 10 allocation paths and their byte counts.

### 1e. Add Custom Instrumentation (if needed)

If the profiler gives aggregate data but not enough detail (e.g., "Arena = 56% of peak" but which Arena method?), add lightweight counters directly to the suspected hot path:

```cpp
// Example: count calls and bytes per method
++stats_alloc_calls; stats_alloc_bytes += size;
++stats_realloc_calls; stats_realloc_bytes += old_size;
```

Log stats in the destructor for objects > 10MB. This gives **ground truth** about which methods are actually called, not which methods COULD be called based on code reading.

**This step prevented us from wasting experiments on Arena::realloc (0 calls) and Arena::allocContinue (0 calls) when 100% of allocation was through alignedAlloc.**

## Phase 2: Identify Candidates from Profile Data

**Now** scan source code — but only the functions identified in Phase 1 traces. Don't scan broadly; focus on the specific call stacks from the profiler.

```
For each top allocation path from Phase 1:
  - Read the source code for that specific function
  - Understand WHY it allocates that much
  - Identify whether it's: avoidable, reducible, or deferrable
  - Propose a code-level change (data structure, algorithm, or logic)
```

Write candidates to `candidates.md` with:
- **Profile evidence:** exact function, bytes, % of total (from Phase 1)
- **Root cause:** why the allocation happens (realloc doubling, unbounded growth, etc.)
- **Proposed fix:** what structural change would reduce it
- **Targeted workload:** a query/test that exercises THIS specific path at scale

### Candidate Validation Checklist

Before any candidate proceeds:
- [ ] Profile stack trace shows this function as a top allocator (>5% of total)
- [ ] Root cause is understood (not guessed from code reading)
- [ ] Proposed fix is structural (data structure, algorithm, logic — NOT constant/threshold tuning)
- [ ] Targeted workload is designed that exercises the EXACT code path
- [ ] Size calculation shows the workload produces allocations large enough to trigger the inefficiency

## Phase 2.75: Verify Workload Triggers the Path

Deploy unmodified baseline, run targeted workload, profile again:
- Does the targeted function appear in the top allocators?
- Are the allocation sizes in the expected range?
- If NOT → the workload is wrong, redesign it. DO NOT PROCEED.

**This step prevented us from optimizing Arena::realloc when groupArray doesn't use Arena for its array growth — it uses PODArray via the system allocator.**

## Phase 3: Experiment Loop

Run experiments **only on profile-confirmed candidates with verified workloads.**

### The Loop

```
1.  Pick top confirmed candidate from candidates.md
2.  If none remain: report to human or re-profile with different workload
3.  Implement the optimization
4.  Build (Release mode for benchmarking — debug symbols not needed here)
5.  Run N>=3 iterations with TARGETED workload:
      deploy → workload → collect RSS → teardown
6.  Run N>=3 baseline iterations (reuse if already collected for this workload)
7.  Compute statistics: mean, stddev, range for both
8.  Decision:
    - Mean improved > 1 stddev AND distributions don't overlap → KEEP
    - Distributions overlap → DISCARD (not statistically significant)
    - Profile shows no change in targeted function → DISCARD (wrong hypothesis)
9.  Record in results.tsv with multi-run stats
10. Repeat
```

### Output Types

Not every finding leads to a code PR. The right output depends on what you find:

| Finding | Right Output |
|---------|-------------|
| Small, self-contained fix with measured impact | **Pull Request** with benchmark data |
| Design-level problem requiring API changes | **Issue** with profiling evidence and proposed design |
| No optimization opportunity after profiling | **Report** documenting what was investigated and why it's not a target |

**An issue with stack traces and a concrete proposal is more valuable than a PR with no measurable impact.**

## Optimization Priority

**Code-level only — NOT configuration changes.**

1. **Data structure changes** — replace a container with a more efficient one
2. **Memory lifecycle changes** — pre-reserve, pool, recycle, release earlier
3. **Algorithm changes** — reduce complexity, eliminate redundant work
4. **Logic changes** — move semantics, lazy evaluation, deferred computation

**NOT optimization:**
- Changing growth factors (2x → 1.5x)
- Changing thresholds (128MB → 64MB)
- Changing initial sizes (4096 → 1024)
- Changing buffer counts or pool sizes

Ask: "Does this change HOW the code works, or just WHAT numbers it uses?"

## Rules

- **Profile before coding** — never implement without stack-level allocation evidence
- **Verify workload exercises the path** — before implementing, not after
- **Multi-run benchmarks** — N>=3, distributions must not overlap for KEEP
- **Instrument when uncertain** — add counters to get ground truth, don't guess from code
- **Right output type** — PR for measured fixes, issue for design proposals, report for dead ends
- **Only edit files** in editable scope from target.md
- **No config tuning** — constants, thresholds, buffer sizes are NOT optimizations
- **Log everything** — results.tsv captures all experiments including failures

## Lessons Learned (from ClickHouse experiments)

These are hard-won lessons from 18+ experiments across 3 pipeline versions:

1. **Aggregate profiling metrics (/proc/status, query_log) don't tell you WHERE memory goes.** You need stack traces. "Arena = 56% of peak" is not actionable; "PODArray::resize called from GroupArrayGeneralImpl::insertResultInto = 536MB" IS actionable.

2. **Code reading produces hypotheses, not facts.** ClickHouse devs documented "quadratic waste in allocContinue" but our workload never triggered it (0 calls). Always validate hypotheses with instrumentation before implementing.

3. **Your optimization must target the function that ACTUALLY allocates, not the one that LOOKS like it should.** Arena::realloc was the obvious target but had 0 calls. The real allocator was PODArray::resize through the system allocator, called during result materialization (not during aggregation).

4. **Generic workloads may never exercise the targeted path.** 100K keys × 50 values = 400 bytes/key — too small to trigger realloc. 1K keys × 50K values = 500MB total — exercises the path. Size calculations matter.

5. **Single-run results are noise.** Process RSS varies 10-20% between identical runs with generic workloads, and ~0.1% with targeted workloads. Always run N>=3 and compare distributions.

6. **Sometimes the right contribution is an issue, not a PR.** ClickHouse's PODArray realloc peak during result materialization requires an API change (estimateResultBytes). Filing an issue with profiling evidence is more valuable than a PR that doesn't work.

7. **Build with debug symbols for profiling, Release for benchmarking.** addressToSymbol/addressToLine return empty strings without debug info. Switch to Release for the actual A/B benchmark.

## Resume Protocol

```bash
# Find where you left off
cat results/<target>/<env>/candidates.md
tail -5 results/<target>/<env>/results.tsv
ls results/<target>/<env>/profiles/

# Read latest profile
cat results/<target>/<env>/profiles/<latest>-stacks.txt
```

## Metric Direction

From target.md: `direction: lower` (e.g., peak_rss_mb) or `direction: higher` (e.g., throughput_qps).
