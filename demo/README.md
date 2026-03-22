# Auto-Optimization Framework — Demo

This demo runs the full optimization loop on a Python HTTP server with 3 intentional memory inefficiencies. It demonstrates:

1. **Baseline establishment** — deploy unmodified code, measure metrics
2. **Experiment iteration** — agent makes code changes, measures impact
3. **Keep/discard decisions** — improvements above noise threshold are kept, marginal changes discarded
4. **Full traceability** — every experiment is a git branch, metrics logged to TSV, summary auto-generated

## Prerequisites

```bash
brew install kubectl kind gettext coreutils
# Docker Desktop must be installed and running
```

## Quick Start

```bash
# 1. Set up kind cluster (one-time)
./demo/setup.sh

# 2. Run the full demo (baseline + 3 experiments, ~5 min)
./demo/run.sh

# 3. View results
cat results/pyserver/local/summary.md

# 4. Clean up
./demo/teardown.sh
```

## What Happens

The demo runs 4 iterations of the optimization loop:

| Step | Change | Expected Result |
|------|--------|-----------------|
| Baseline | Unmodified server | ~24 MB RSS, ~57ms p99 latency |
| Exp 001 | Cap history + shallow copy | ~22 MB RSS (-7.5%) → **KEEP** |
| Exp 002 | List → set for O(1) dedup | ~22 MB RSS, 31ms latency (-45%) → **KEEP** |
| Exp 003 | Generators + heapq for stats | <1% improvement → **DISCARD** |

## The Server's Intentional Inefficiencies

1. **`DATA_STORE` is a list** — membership checks are O(n) instead of O(1) with a set
2. **`HISTORY` grows unbounded** — every `/process` call deep-copies the entire data store
3. **Stats materializes full intermediate lists** — generators would avoid this

## Artifacts After Demo

```
results/pyserver/local/
├── results.tsv              # tab-separated metrics for all experiments
├── summary.md               # human-readable report
└── logs/
    ├── baseline-metrics.log
    ├── exp001-metrics.log
    ├── exp002-metrics.log
    └── exp003-metrics.log

targets/pyserver/src/        # git repo with branches:
  autoopt/pyserver/poc-baseline
  autoopt/pyserver/poc-exp001
  autoopt/pyserver/poc-exp002
  autoopt/pyserver/poc-exp003
```

## How This Applies to Real Projects

Replace `targets/pyserver/` with any project:
- `Dockerfile` — how to build it
- `k8s.yaml` — how to deploy it
- `workload.sh` — how to exercise it
- `target.md` — what metric to optimize, what files to edit
- `hints.md` — domain knowledge for the AI agent

The framework handles everything else: build, deploy, measure, track, report.
