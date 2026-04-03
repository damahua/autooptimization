# autooptimization

A methodology for autonomous AI-driven code optimization. An AI agent follows a structured protocol (`program.md`) to profile unfamiliar codebases, identify bottlenecks from evidence, implement optimizations, and validate results with statistically rigorous A/B benchmarks.

Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).

## What This Is

1. **A methodology** (`program.md`) — a detailed protocol for profile-first optimization that an AI agent follows. Includes workload discovery, stack-level profiling, candidate validation, experiment loops, and 12 hard-won lessons from real optimization attempts.
2. **Target definitions** (`targets/`) — codebases to optimize, each with its own Dockerfile, K8s manifest, workload scripts, and domain hints for the agent.
3. **Annotated examples** (`examples/`) — shell scripts showing lifecycle patterns (build, deploy, profile, collect, etc.) that the agent adapts per target.
4. **Experiment results** (`results/`) — metrics, profiles, and logs from optimization experiments on each target.

## How It Works

1. Point an AI agent at `program.md` and a target (e.g., `targets/clickhouse/`)
2. The agent profiles the target with production-grade tools to find real bottlenecks
3. It identifies optimization candidates backed by stack-level profiling evidence
4. It runs experiments: implement, build, deploy, A/B benchmark (N>=3), keep/discard
5. Everything is recorded in `results/<target>/` — including failures

The agent runs commands directly — it does not use a pipeline dispatcher. The `examples/lifecycle/` scripts are reference patterns it learns from. For every experiment, the agent generates **reproducible scripts** in `results/<target>/<env>/<exp_id>/` — a human can re-run any experiment by executing 5 shell scripts in order.

## What the Agent Actually Does

For **ClickHouse**, the agent used `system.trace_log` with `trace_type='Memory'` to get stack-level allocation traces, identifying `ColumnString::shrinkToFit` as the #1 allocator (1576 MB). It implemented hash table prefetch for string GROUP BY, achieving 8% latency reduction.

For **Chroma**, the agent used `/proc/PID/smaps` for memory region analysis and jemalloc profiling (`_RJEM_MALLOC_CONF=prof:true`) to confirm 97% of memory was in hnswlib C++ via FFI. It then implemented TurboQuant 4-bit vector quantization, reducing peak RSS by 40%.

For **DataFusion**, the agent identified 8.5x write amplification in the spill path and implemented a gc_view_arrays optimization.

## Project Structure

```
autooptimization/
├── program.md              # AI agent methodology (the core of the project)
├── examples/
│   ├── lifecycle/          # Annotated lifecycle script patterns
│   ├── kind-cluster/       # Local K8s cluster setup
│   └── demo/               # End-to-end demo with pyserver target
├── targets/
│   ├── clickhouse/         # ClickHouse optimization target
│   ├── chroma/             # Chroma vector DB target
│   ├── rocksdb/            # RocksDB target
│   └── pyserver/           # Python server (demo target)
└── results/                # Experiment logs, metrics, and reproducible scripts
    └── <target>/<env>/<exp_id>/
        ├── build.sh        # exact build commands
        ├── deploy.sh       # exact deploy commands
        ├── workload.sh     # exact benchmark workload
        ├── collect.sh      # exact metric collection
        ├── teardown.sh     # cleanup
        ├── metrics.log     # measured results
        ├── diff.patch      # the code change
        └── README.md       # hypothesis, reproduction steps, results
```

## Quick Start

```bash
# 1. Read the methodology
cat program.md

# 2. Set up a local K8s cluster (optional, for targets that need it)
./examples/kind-cluster/setup.sh

# 3. Run the pyserver demo (shows the full optimization loop)
./examples/demo/run.sh

# 4. Point your AI agent at a real target
# Agent reads: program.md + targets/<target>/target.md + targets/<target>/hints.md
```

## Targets

| Target | Language | Profiling Tools Used | Key Result |
|--------|----------|---------------------|------------|
| ClickHouse | C++ | `system.trace_log` (memory + CPU traces) | 8% string GROUP BY latency reduction |
| Chroma | Rust/C++ | `/proc/smaps`, jemalloc profiling | 40% peak RSS reduction (TurboQuant) |
| DataFusion | Rust | Custom instrumentation | 8.5x spill write amplification reduction |
| RocksDB | C++ | Stack-level allocation tracing | IODebugContext thread-local optimization |
| pyserver | Python | `/proc/status` VmHWM | Demo target with intentional inefficiencies |

## Optimization Priority

Code-level only — NOT configuration tuning:
1. Data structure changes
2. Memory allocation patterns
3. Algorithmic improvements
4. Processing logic optimization

See `program.md` for the full methodology, experiment protocol, and lessons learned.
