# autooptimization

A framework for autonomous AI-driven code optimization. An AI agent continuously optimizes a target project's source code by deploying to Kubernetes, benchmarking, and deciding whether to keep or discard each change — running in a loop until a human stops it.

Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).

## How It Works

1. **Pick a target** (codebase to optimize) and an **environment** (where to deploy)
2. **Run a baseline** — build, deploy, run workload, collect metrics
3. **Experiment loop** (runs forever until stopped):
   - Analyze source code for optimization opportunities
   - Create a branch, make code changes, commit
   - Build → Deploy (K8s) → Workload → Collect metrics → Validate
   - If the primary metric improved: **keep**. Otherwise: **discard**
   - Record everything in `results.tsv`, repeat

## Prerequisites

- docker, kubectl, kind, git, envsubst (gettext), bc, curl

## Project Structure

```
autooptimization/
├── program.md              # AI agent instructions
├── run.sh                  # Entrypoint: ./run.sh <env> <script> <target>
├── envs/
│   ├── base/               # Default lifecycle scripts (build, deploy, collect, ...)
│   └── local/              # Kind cluster overrides
├── targets/
│   ├── clickhouse/         # ClickHouse optimization target
│   └── pyserver/           # Python server optimization target
├── results/                # Experiment logs and metrics per target/env
└── demo/                   # Demo setup and scripts
```

## Usage

```bash
# 1. Set up a Kind cluster
./demo/setup.sh

# 2. Run the lifecycle for a target
./run.sh local build.sh <target>
./run.sh local deploy.sh <target>
./run.sh local workload.sh <target>
./run.sh local collect.sh <target>
./run.sh local validate.sh <target>
./run.sh local teardown.sh <target>
```

See `program.md` for the full AI agent protocol, experiment loop details, and results format.

## Optimization Priority

The framework focuses on **real code-level optimizations**, not configuration tuning:

1. Data structure changes
2. Memory allocation patterns
3. Algorithmic improvements
4. Processing logic optimization
5. CPU optimization (cache locality, vectorization)
