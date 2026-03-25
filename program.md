# autooptimization

This is a framework for autonomous AI-driven code optimization. Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).

## Prerequisites

Required tools: docker, kubectl, kind, git, envsubst (from gettext), bc, curl

## Setup

To set up a new optimization run, work with the user to:

1. **Agree on target, environment, metric, and tag:**
   - Target: which project to optimize (e.g., `clickhouse`)
   - Environment: where to deploy (e.g., `local`)
   - Primary metric: what to optimize (e.g., `peak_rss_mb`)
   - Tag: identifier for this run (e.g., `mar24`)

2. **Read the target config:**
   - `targets/<target>/target.md` — repo, metric, scope, constraints
   - `targets/<target>/hints.md` — optimization hints (if exists)

3. **Clone target source** (if not already present):
   ```bash
   REPO_URL=<from target.md>
   BRANCH=<from target.md>
   git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "targets/<target>/src"
   ```

4. **Verify environment:**
   ```bash
   which docker kubectl git
   kubectl --context kind-autoopt cluster-info  # for local env
   docker info
   ```

5. **Initialize results:**
   ```bash
   mkdir -p "results/<target>/<env>/logs" "results/<target>/<env>/profiles"
   echo -e "exp_id\tbranch\tparent_branch\tcommit\tmetric_name\tmetric_value\tbaseline_value\tdelta_vs_baseline\tdelta_vs_parent\tcpu_pct\tlatency_p99_ms\terror_rate\tpod_restarts\tstatus\tprofile_summary\tdescription" > "results/<target>/<env>/results.tsv"
   ```

## Phase 1: Scan — Enumerate Optimization Candidates

Before running any experiments, scan the target source code to enumerate ALL possible code-level optimizations.

```
6. Read target source code in editable scope (from target.md)
7. Read hints.md if present
8. List ALL possible code-level optimizations as candidates
9. Write candidates to results/<target>/<env>/candidates.md
```

Each candidate should include:
- **ID**: C1, C2, C3...
- **Description**: What the optimization does
- **Files**: Which source files would be modified
- **Hypothesis**: Why this should reduce the primary metric
- **Expected impact**: Rough estimate (high/medium/low)

## Phase 2: Profile Baseline — Validate Candidates

Profile the unmodified code to establish WHERE resources are actually spent. This is the critical step that prevents wasted experiments.

```
10. Create baseline branch:
    cd targets/<target>/src
    git checkout -b autoopt/<target>/<tag>-baseline
    cd ../../..

11. Build, deploy, run workload:
    ./run.sh <env> build.sh <target>
    ./run.sh <env> deploy.sh <target>
    ./run.sh <env> workload.sh <target>

12. Profile baseline:
    PROFILE_LABEL=baseline ./run.sh <env> profile.sh <target>

13. Collect metrics:
    ./run.sh <env> collect.sh <target> > results/<target>/<env>/logs/baseline-metrics.log

14. Analyze profile:
    PROFILE_LABEL=baseline ./run.sh <env> analyze.sh <target>

15. Validate baseline:
    ./run.sh <env> validate.sh <target>

16. Teardown:
    ./run.sh <env> teardown.sh <target>

17. Record baseline in results.tsv
```

## Phase 2.5: Validate Candidates Against Profile

Now cross-reference the candidates from Phase 1 against the profile data from Phase 2.

```
18. Read results/<target>/<env>/profiles/baseline-analysis.txt
19. For each candidate:
    - Does the profile show the targeted code path is a significant consumer?
    - Threshold: >5% of total RSS or >5% of CPU samples
    - Mark as CONFIRMED or UNCONFIRMED
20. Update candidates.md with profile evidence for each candidate
21. Sort CONFIRMED candidates by expected impact (profile-weighted)
```

**candidates.md format:**

```markdown
# Optimization Candidates

## Confirmed (profile-validated hot paths)
| ID | Description | Files | Profile Evidence | Expected Impact | Status |
|----|-------------|-------|-----------------|-----------------|--------|
| C1 | ... | ... | heap=512MB (56% of peak) | high | pending |

## Unconfirmed (not significant in profile)
| ID | Description | Files | Profile Evidence | Status |
|----|-------------|-------|-----------------|--------|
| U1 | ... | ... | 12.5MB (1.5% of peak) | skipped |
```

## Phase 2.75: Design Targeted Workload Per Candidate

**This is the critical step that was missing.** The generic workload may not exercise the specific code path a candidate targets. Before implementing any candidate, design a workload that **guarantees** the targeted path is stressed.

For each CONFIRMED candidate:

```
22. Identify the exact code path the candidate optimizes
    - What function/data structure is changed?
    - What allocation/computation pattern triggers it?
    - At what data scale does the inefficiency become significant?

23. Design a stress test query/workload that exercises that specific path:
    - The workload MUST produce allocations large enough to trigger the targeted inefficiency
    - Calculate: how many iterations, what data size, what key cardinality is needed
    - Example: if optimizing Arena::realloc waste for large aggregate states,
      the workload must produce per-key states >1MB (not 400 bytes)

24. Verify the workload triggers the path BEFORE implementing:
    - Deploy unmodified baseline
    - Run the targeted workload
    - Profile and check: does the targeted function/path appear as a significant consumer?
    - If NOT → the workload is wrong, redesign it
    - If YES → the workload is valid, proceed to implementation

25. Write the stress test to results/<target>/<env>/workloads/exp<NNN>-workload.sh
    or add targeted queries to the profile workload
```

**Workload design checklist:**
- [ ] Does the workload force the targeted code path to execute? (not just nearby code)
- [ ] Is the data scale large enough for the inefficiency to manifest? (e.g., per-key state > threshold that triggers realloc)
- [ ] Can we verify the path is exercised via profiling? (e.g., ArenaAllocChunks > 0, specific function appears in CPU profile)
- [ ] Is the workload reproducible? (deterministic data generation, fixed row counts)

**Example — Arena::realloc waste candidate:**
```
BAD workload:  groupArray on 100K keys × 50 values = 400 bytes/key (never reallocs)
GOOD workload: groupArray on 1K keys × 100K values = 800KB/key (forces many reallocs per key)
```

The good workload produces per-key states that overflow Arena chunk boundaries, triggering the exact realloc → copy → waste path the optimization targets.

Update candidates.md with the targeted workload for each confirmed candidate.

## Phase 3: Experiment Loop — Profile-Validated Only

Once candidates are validated AND targeted workloads are designed, run experiments **only on confirmed candidates with their targeted workloads**. Every experiment includes profiling for before/after comparison.

### Optimization Priority

**Focus on real code-level optimizations — NOT configuration changes.**

Priority order (highest first):
1. **Data structure changes** — replace a container with a more efficient one
2. **Memory allocation patterns** — add pooling, reuse, eliminate copies
3. **Algorithmic improvements** — reduce complexity, eliminate redundant work
4. **Processing logic optimization** — move semantics, avoid re-computation
5. **CPU optimization** — cache locality, branch prediction, vectorization

Configuration tuning (buffer sizes, growth factors, threshold values) is NOT code optimization. Ask:
- "Can this allocation be avoided entirely?"
- "Can this object be reused instead of re-created?"
- "Is this the right data structure for this access pattern?"
- "Is this algorithm optimal for the data size?"

### The Loop

Run this loop **forever** until the human stops you:

```
1.  Read candidates.md — pick top CONFIRMED candidate not yet tried
2.  If no confirmed candidates remain:
    - Rescan code for new ideas (go back to Phase 1 step 6)
    - Or report to human: "All confirmed candidates exhausted"
3.  Read the targeted workload for this candidate (from Phase 2.75)
4.  Verify the targeted workload exercises the code path:
    - Deploy unmodified parent, run targeted workload, profile
    - Confirm the targeted function/allocation appears as significant in profile
    - If NOT: redesign workload, do not proceed with implementation
5.  Determine parent: last "keep" branch from results.tsv (or baseline)
6.  cd targets/<target>/src
    git checkout <parent_branch>
    git checkout -b autoopt/<target>/<tag>-exp<NNN>
7.  Implement the optimization targeting the CONFIRMED hot path
8.  git add -A && git commit -m "[autoopt] exp<NNN>: <description>"
9.  cd ../../..
10. Build: ./run.sh <env> build.sh <target>
11. Run N>=3 measurement iterations (deploy → targeted workload → collect → teardown):
    For each run:
      a. ./run.sh <env> deploy.sh <target>
      b. Run the TARGETED workload (not generic) for this candidate
      c. ./run.sh <env> collect.sh <target>  — record peak_rss_mb
      d. On first run only: PROFILE_LABEL=exp<NNN> ./run.sh <env> profile.sh <target>
      e. ./run.sh <env> teardown.sh <target>
    Collect all N metric values.
12. Also run N>=3 iterations with UNMODIFIED parent (same targeted workload):
    - If baseline runs for this workload already exist, reuse them
    - Otherwise run N>=3 baseline iterations now
13. PROFILE_LABEL=exp<NNN> PROFILE_COMPARE_TO=<parent_label> ./run.sh <env> analyze.sh <target>
14. ./run.sh <env> validate.sh <target>
15. Compute statistics:
    - Baseline: mean, stddev, range (N values)
    - Experiment: mean, stddev, range (N values)
    - Delta of means, and whether distributions overlap
16. Decision (requires BOTH profile evidence AND statistical significance):
    - Mean improved > 1 stddev AND profile diff confirms targeted area → KEEP
    - Distributions overlap (delta < stddev) → DISCARD (not significant)
    - Profile diff shows NO change in targeted area → DISCARD (wrong hypothesis)
    - Metric regressed → DISCARD
17. Record in results.tsv (include profile_summary AND multi-run stats)
18. Update summary.md and candidates.md
19. Repeat from step 1
```

### Why Multi-Run Matters

Process-level RSS (VmHWM) varies 10-20% between identical runs due to:
- jemalloc/malloc internal state and thread cache sizing
- Kernel memory management decisions (page coalescing, THP)
- Background processes (ClickHouse merges, log flushes, compaction)
- Timing of when peak occurs relative to measurement

A single run showing "-7.8%" means nothing if the natural variance is ±17%. The framework MUST collect multiple measurements to distinguish signal from noise.

### Why Targeted Workloads Matter

A generic workload may never exercise the specific code path being optimized:
- Optimizing Arena::realloc waste requires per-key states large enough to trigger realloc (>chunk size)
- Optimizing hash table growth requires enough distinct keys to trigger multiple resizes
- Optimizing sort buffer allocation requires ORDER BY on enough data to spill

If the workload doesn't trigger the targeted path, the optimization will show zero effect regardless of whether the code change is correct. **Verify the path is exercised before implementing.**

## Rules

- **Only edit files** in editable scope from target.md — never framework scripts
- **Profile before experimenting** — never implement an optimization without profile evidence
- **Build/deploy crash handling:** try to fix. After 3 consecutive failures on the same experiment, discard it and try a new idea
- **Log everything** to results.tsv regardless of outcome
- **Never stop** — iterate until human interrupts
- **Simpler is better** — same metric with less code is a win
- **One agent per target+env** — do not run concurrent experiments on the same target+environment
- **Safety:** if SAFETY_LEVEL=approval_required (check env.conf), pause after git commit and show the diff before deploying
- **No config tuning** — do not change constants, thresholds, buffer sizes, or growth factors as optimizations

## Results Format

### results.tsv (tab-separated)

```
exp_id	branch	parent_branch	commit	metric_name	metric_value	baseline_value	delta_vs_baseline	delta_vs_parent	cpu_pct	latency_p99_ms	error_rate	pod_restarts	status	profile_summary	description
```

Status values: `keep`, `discard`, `crash`, `invalid`, `constraint_violation`, `timeout`

Profile summary: one-line evidence, e.g. `"heap -40.3MB (-4.1%), top: Arena::addMemoryChunk -14.6%"`

### Structured commit messages

```
[autoopt] exp003: replace hash map with vector in MergeTree reader

Target: clickhouse
Environment: local
Metric: peak_rss_mb
Baseline: 1335.2
Parent: 1300.1 (exp001)
Result: 1260.4
Delta vs baseline: -5.6%
Delta vs parent: -3.1%
Profile evidence: heap 980MB -> 940MB (-4.1%), Arena::addMemoryChunk -14.6% samples
Status: keep
```

### summary.md

After each experiment, regenerate `results/<target>/<env>/summary.md` with:
- Best result and current frontier branch
- Full experiment timeline table (with profile_summary column)
- Frontier lineage (chain of "keep" experiments)
- What worked / what didn't work (with profile evidence)
- Constraint status
- Profile highlights (top memory consumers, how they changed)

## Resume Protocol

If you are resuming a previous run:

```bash
# Find last experiment
tail -1 results/<target>/<env>/results.tsv

# Find frontier (last keep)
grep "keep" results/<target>/<env>/results.tsv | tail -1

# Read latest profile analysis
cat results/<target>/<env>/profiles/<latest>-analysis.txt

# Read candidates
cat results/<target>/<env>/candidates.md

# Checkout frontier and continue
cd targets/<target>/src
git checkout <frontier_branch>
```

## Metric Direction

Read `direction` from target.md:
- `direction: lower` → smaller values are better (e.g., peak_rss_mb, latency_p99_ms)
- `direction: higher` → larger values are better (e.g., throughput_qps)

The keep/discard decision must account for the direction.
