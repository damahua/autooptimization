# autooptimization

This is a framework for autonomous AI-driven code optimization. Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).

## Prerequisites

Required tools: docker, kubectl, kind, git, envsubst (from gettext), bc, curl, perl

Optional (for profiling/flame graphs):
```bash
git clone https://github.com/brendangregg/FlameGraph.git tools/FlameGraph
```

## Setup

To set up a new optimization run, work with the user to:

1. **Agree on target, environment, metric, and tag:**
   - Target: which project to optimize (e.g., `clickhouse`)
   - Environment: where to deploy (e.g., `local`)
   - Primary metric: what to optimize (e.g., `peak_rss_mb`)
   - Tag: identifier for this run (e.g., `mar22`)

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
   mkdir -p "results/<target>/<env>/logs"
   echo -e "exp_id\tbranch\tparent_branch\tcommit\tmetric_name\tmetric_value\tbaseline_value\tdelta_vs_baseline\tdelta_vs_parent\tcpu_pct\tlatency_p99_ms\terror_rate\tpod_restarts\tstatus\tdescription" > "results/<target>/<env>/results.tsv"
   ```

6. **Create baseline branch and run baseline:**
   ```bash
   cd targets/<target>/src
   git checkout -b autoopt/<target>/<tag>-baseline
   cd ../../..
   ./run.sh <env> build.sh <target>
   ./run.sh <env> deploy.sh <target>
   ./run.sh <env> workload.sh <target>
   ./run.sh <env> collect.sh <target> > results/<target>/<env>/logs/baseline-metrics.log
   ./run.sh <env> validate.sh <target>
   ./run.sh <env> teardown.sh <target>
   ```

7. **Record baseline** in results.tsv and confirm it looks good.

## Experiment Loop

Once setup is confirmed, run this loop **forever** until the human stops you:

```
1.  Read results.tsv to know what's been tried
2.  Scan target source code in editable scope (from target.md)
3.  Read hints.md if present
4.  Identify an optimization opportunity
5.  Determine parent: last "keep" branch from results.tsv (or baseline)
6.  cd targets/<target>/src
    git checkout <parent_branch>
    git checkout -b autoopt/<target>/<tag>-exp<NNN>
7.  Edit source code to implement the optimization
8.  git add -A && git commit -m "[autoopt] exp<NNN>: <description>"
9.  cd ../../..
10. ./run.sh <env> build.sh <target>    > results/<target>/<env>/logs/exp<NNN>-build.log 2>&1
11. ./run.sh <env> deploy.sh <target>   > results/<target>/<env>/logs/exp<NNN>-deploy.log 2>&1
12. ./run.sh <env> workload.sh <target> > results/<target>/<env>/logs/exp<NNN>-workload.log 2>&1
13. ./run.sh <env> collect.sh <target>  > results/<target>/<env>/logs/exp<NNN>-metrics.log
14. ./run.sh <env> validate.sh <target> > results/<target>/<env>/logs/exp<NNN>-validate.log 2>&1
15. Read primary metric from exp<NNN>-metrics.log
16. Check constraints from target.md
17. Decision:
    - Primary metric improved (above MIN_IMPROVEMENT_PCT) AND constraints pass AND validation pass → KEEP
    - Otherwise → DISCARD
18. Record in results.tsv
19. ./run.sh <env> teardown.sh <target>
20. Update summary.md
21. Repeat from step 1
```

## Profiling-Driven Mode

Profiling is a first-class feature. Use it to identify hot paths and guide experiment selection.

### Setup

Install FlameGraph tools (one-time):
```bash
git clone https://github.com/brendangregg/FlameGraph.git tools/FlameGraph
```

### Optimization Methodology

The framework follows a rigorous profiling-driven optimization process. Do NOT skip steps or guess at optimizations.

#### Step 1: Understand the Target

Before any optimization, understand the target's architecture and typical use cases:
- Read `target.md` — what is this software? what are its critical code paths?
- Read `hints.md` — what domain knowledge exists?
- Research the target's documentation — what are typical workloads?
- Understand the data flow: how does a request/query flow through the code?

#### Step 2: Design Representative Workload

The workload MUST exercise the code paths that matter in production:
- Study the target's typical use cases (e.g., for a database: OLAP queries, inserts, scans)
- Design queries/requests that stress the areas listed in `target.md` editable scope
- Use realistic data sizes (not toy data) — at least 1M+ rows for databases
- Include a mix of operations that reflect real usage patterns
- Update `targets/<target>/workload.sh` if the current workload is insufficient

#### Step 3: Profile the Baseline

```bash
./run.sh <env> profile.sh <target>    # PROFILE_TYPE=cpu|memory|both (default: both)
```

The profiler generates:
- `*.folded` files — folded stacks for flame graph generation (FlameGraph tool format)
- `profiling_summary.txt` — structured analysis for agent consumption
- `*_flamegraph.svg` — interactive flame graph visualizations

#### Step 4: Analyze Profiling Data

Read `profiling_summary.txt` and analyze each section:

**Section A — Memory allocation hot paths:**
- Which functions allocate the most total bytes?
- What is the CALL CHAIN? (func ← caller ← grandcaller tells you WHY it's called)
- What is the allocation SIZE distribution? (many small = pooling candidate, few large = buffer sizing)

**Section B — CPU hot paths:**
- Which functions consume the most CPU (excluding idle threads)?
- What is the call chain? What operation triggers this?

**Section C — Per-query resource usage:**
- Which query types use the most memory? Those are optimization targets.
- Are some queries disproportionately expensive?

**Section D — Server memory state:**
- Are caches oversized for the workload? (allocated >> used)
- Is jemalloc retaining too much memory?

**Section E — Allocation patterns:**
- Functions with high alloc AND dealloc counts have "churn" — candidates for object pooling
- High churn_bytes with low net_bytes = objects being created and destroyed repeatedly

#### Step 5: Classify Each Optimization Opportunity

For each hot path identified, classify it:

| Pattern | What to look for | Optimization |
|---------|-----------------|--------------|
| **Unnecessary allocation** | Object created every call but could be reused | Object pooling, pre-allocation, arena allocator |
| **Oversized buffer** | Buffer allocated much larger than data written | Reduce buffer size, use dynamic sizing |
| **Unnecessary copy** | Deep copy where move/reference works | Use move semantics, pass by reference |
| **Wrong data structure** | List used for lookups, unsorted for binary search | Replace with hashmap, sorted container |
| **Redundant computation** | Same calculation repeated across calls | Cache result, memoize |
| **Alloc/free churn** | High churn_bytes in Section E | Pool objects, use arena allocator |
| **Cache-unfriendly** | Data scattered across memory | Array-of-structs → struct-of-arrays |
| **Algorithmic** | O(n²) pattern in hot loop | Use better algorithm |
| **Config oversizing** | Cache/pool allocated >> used (Section D) | Reduce config values |

#### Step 6: Locate Hot Functions in Source Code

For each optimization candidate:
```bash
# Find the function in source
grep -rn "function_name" targets/<target>/src/src/ --include="*.cpp" --include="*.h"
```
- Read the source code at that location
- Understand the context: loop? constructor? per-request?
- Trace up the call chain: who calls this and how often?

#### Step 7: Create Experiment Plan

Before making ANY code changes, write an experiment plan:
- What specifically to change (file, function, line)
- WHY this should help (based on profiling data)
- WHICH workload queries exercise this path
- Expected impact (quantified from profiling: "this path allocates X bytes, fix should save Y%")
- Risks (what could break?)

#### Step 8: Execute Experiments (one at a time)

Each experiment in its own branch:
```bash
cd targets/<target>/src
git checkout <frontier_branch>
git checkout -b autoopt/<target>/<tag>-exp<NNN>
# make the change
git commit -m "[autoopt] exp<NNN>: <what and why>"
```

Then run the full pipeline:
```bash
./run.sh <env> build.sh <target>
./run.sh <env> deploy.sh <target>
./run.sh <env> workload.sh <target>
./run.sh <env> profile.sh <target>     # RE-PROFILE with same workload
./run.sh <env> collect.sh <target>
./run.sh <env> validate.sh <target>
```

#### Step 9: Compare Profiles (Before vs After)

```bash
BASELINE_PROFILE_DIR=results/<target>/<env>/profiles/baseline \
CURRENT_PROFILE_DIR=results/<target>/<env>/profiles \
./run.sh <env> compare.sh <target>
```

This generates differential flame graphs (red = regression, blue = improvement) and a comparison summary. Check:
- Did the targeted hot path actually shrink?
- Did any other path grow as a side effect?
- Did the primary metric (RSS, CPU) improve overall?

#### Step 10: Keep/Discard and Iterate

After fixing the biggest bottleneck, the NEXT bottleneck is revealed. Re-profile and repeat.

The optimization is done when:
- Primary metric meets the target
- Remaining hot paths are in read-only scope (can't change)
- Further improvements are below noise threshold

### Scripts Reference

```bash
./run.sh <env> profile.sh <target>     # profile: delegates to target, generates flame graphs
./run.sh <env> compare.sh <target>     # compare: diff flame graphs (before vs after)
```

### Target profile.sh Contract

Each target that supports profiling provides `targets/<target>/profile.sh`:

- **Input env vars:** `SERVICE_HOST`, `SERVICE_PORT`, `PROFILE_TYPE` (cpu|memory|both), `PROFILE_DIR`
- **Outputs:**
  - `$PROFILE_DIR/<name>.folded` — folded stack format (`frame1;frame2;...;frameN\tcount`)
  - `$PROFILE_DIR/profiling_summary.txt` — structured analysis with sections:
    - A: Memory allocation hot paths with call chains
    - B: CPU hot paths with call chains (excluding idle)
    - C: Per-query resource usage
    - D: Server memory state
    - E: Allocation patterns (pooling candidates)
- **Exit:** 0 on success

The framework's `envs/base/profile.sh` generates flame graphs from `.folded` files automatically using Brendan Gregg's FlameGraph tools.

---

## Rules

- **Only edit files** in editable scope from target.md — never framework scripts
- **Build/deploy crash handling:** try to fix. After 3 consecutive failures on the same experiment, discard it and try a new idea
- **Log everything** to results.tsv regardless of outcome
- **Never stop** — iterate until human interrupts
- **Simpler is better** — same metric with less code is a win
- **One agent per target+env** — do not run concurrent experiments on the same target+environment
- **Safety:** if SAFETY_LEVEL=approval_required (check env.conf), pause after git commit and show the diff before deploying

## Results Format

### results.tsv (tab-separated)

```
exp_id	branch	parent_branch	commit	metric_name	metric_value	baseline_value	delta_vs_baseline	delta_vs_parent	cpu_pct	latency_p99_ms	error_rate	pod_restarts	status	description
```

Status values: `keep`, `discard`, `crash`, `invalid`, `constraint_violation`, `timeout`

### Structured commit messages

```
[autoopt] exp003: reduce MergeTree allocator block size

Target: clickhouse
Environment: local
Metric: peak_rss_mb
Baseline: 4200.3
Parent: 4100.2 (exp001)
Result: 3850.1
Delta vs baseline: -8.3%
Delta vs parent: -6.1%
Status: keep
```

### summary.md

After each experiment, regenerate `results/<target>/<env>/summary.md` with:
- Best result and current frontier branch
- Full experiment timeline table
- Frontier lineage (chain of "keep" experiments)
- What worked / what didn't work
- Constraint status

## Resume Protocol

If you are resuming a previous run:

```bash
# Find last experiment
tail -1 results/<target>/<env>/results.tsv

# Find frontier (last keep)
grep "keep" results/<target>/<env>/results.tsv | tail -1

# Checkout frontier and continue
cd targets/<target>/src
git checkout <frontier_branch>
```

## Metric Direction

Read `direction` from target.md:
- `direction: lower` → smaller values are better (e.g., peak_rss_mb, latency_p99_ms)
- `direction: higher` → larger values are better (e.g., throughput_qps)

The keep/discard decision must account for the direction.
