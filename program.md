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

## Phase 3: Experiment Loop — Profile-Validated Only

Once candidates are validated, run experiments **only on confirmed candidates**. Every experiment includes profiling for before/after comparison.

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
3.  Read the profile analysis for the parent (baseline or last keep)
4.  Determine parent: last "keep" branch from results.tsv (or baseline)
5.  cd targets/<target>/src
    git checkout <parent_branch>
    git checkout -b autoopt/<target>/<tag>-exp<NNN>
6.  Implement the optimization targeting the CONFIRMED hot path
7.  git add -A && git commit -m "[autoopt] exp<NNN>: <description>"
8.  cd ../../..
9.  ./run.sh <env> build.sh <target>    > results/<target>/<env>/logs/exp<NNN>-build.log 2>&1
10. ./run.sh <env> deploy.sh <target>   > results/<target>/<env>/logs/exp<NNN>-deploy.log 2>&1
11. ./run.sh <env> workload.sh <target> > results/<target>/<env>/logs/exp<NNN>-workload.log 2>&1
12. PROFILE_LABEL=exp<NNN> ./run.sh <env> profile.sh <target>
13. ./run.sh <env> collect.sh <target>  > results/<target>/<env>/logs/exp<NNN>-metrics.log
14. PROFILE_LABEL=exp<NNN> PROFILE_COMPARE_TO=<parent_label> ./run.sh <env> analyze.sh <target>
15. ./run.sh <env> validate.sh <target> > results/<target>/<env>/logs/exp<NNN>-validate.log 2>&1
16. Read primary metric from exp<NNN>-metrics.log
17. Read profile diff from profiles/exp<NNN>-vs-<parent>-diff.txt
18. Check constraints from target.md
19. Decision:
    - Metric improved AND profile diff confirms targeted area improved → KEEP
    - Profile diff confirms targeted area improved but metric within noise → KEEP (profile-confirmed)
    - Profile diff shows NO change in targeted area → DISCARD (wrong hypothesis)
    - Metric regressed → DISCARD
    - Otherwise → DISCARD
20. Record in results.tsv (include profile_summary column)
21. ./run.sh <env> teardown.sh <target>
22. Update summary.md and candidates.md
23. Repeat from step 1
```

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
