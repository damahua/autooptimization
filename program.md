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

### Optimization Priority

**Focus on real code-level optimizations — NOT configuration changes.**

Priority order (highest first):
1. **Data structure changes** — replace a container with a more efficient one (vector → arena, map → flat_hash_map, list → set)
2. **Memory allocation patterns** — change growth strategies, add object pooling, reuse objects instead of re-allocating, eliminate unnecessary copies
3. **Algorithmic improvements** — reduce complexity (O(n²) → O(n log n)), eliminate redundant work, batch operations
4. **Processing logic optimization** — remove unnecessary copies/clones, use move semantics, avoid re-computation
5. **CPU optimization** — improve cache locality, reduce branch mispredictions, vectorize hot loops
6. ~~Configuration constant changes~~ — only as a last resort when code changes are not feasible

Configuration tuning (buffer sizes, cache sizes, thread pool counts) is operational tuning, not software optimization. The framework exists to find and make code-level improvements.

When analyzing a hot path, ask:
- "Can this allocation be avoided entirely?"
- "Can this object be reused instead of re-created?"
- "Can this copy be eliminated with a reference or move?"
- "Is this the right data structure for this access pattern?"
- "Is this algorithm optimal for the data size?"

### Experiment Loop

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
