# ClickHouse Source-Level Optimization Plan

## Objective

Optimize ClickHouse memory usage by modifying C++ source code, guided by profiling data.
Build from source, deploy, benchmark, profile, identify hot paths, optimize, verify.

## Prerequisites

- Docker Desktop: 16 CPUs, 7.6 GiB (sufficient)
- Kind cluster "autoopt" running
- ClickHouse source with submodules (full clone needed)
- Two-stage build: Dockerfile.builder (ccache) + Dockerfile (thin runtime)

## Phase 1: Setup (one-time, ~60-90 min)

1. Clone ClickHouse with submodules (recursive)
2. Build the builder Docker image (install clang, cmake, ninja, ccache)
3. First source build (cold ccache — longest step)
4. Deploy source-built ClickHouse
5. Verify it works (run workload, collect baseline)

## Phase 2: Benchmark & Profile

1. Run workload with larger dataset (1M+ rows if feasible, or 100K with more iterations)
2. Profile CPU and memory (system.trace_log)
3. Analyze profiling data:
   - Section A: Memory allocation call chains
   - Section B: CPU hot paths (non-idle)
   - Section E: Alloc/free churn
4. Generate flame graphs

## Phase 3: Identify Hot Paths & Plan Experiments

For each hot path:
1. Find the function in ClickHouse source (grep/search)
2. Read the code — understand WHY it's hot
3. Classify the optimization pattern
4. Propose a specific code change
5. Estimate impact from profiling data

## Phase 4: Execute Experiments (iterate)

For each experiment:
1. Create branch: autoopt/clickhouse/source-exp<NNN>
2. Edit source code
3. Incremental build (ccache — should be 2-10 min)
4. Deploy → workload → profile → collect
5. Compare profiles (before/after)
6. Keep/discard decision
7. Record in results.tsv

## Phase 5: Summary

Generate final summary with:
- All experiments and results
- Cumulative improvement
- Before/after flame graph comparison
- Recommendations for production

## Known Hot Paths (from profiling)

| Function | Allocation | Source Location |
|----------|-----------|----------------|
| Memory<Allocator>::alloc() | 1.25 GiB | src/Common/PODArray.h:132 |
| MergedBlockOutputStream ctor | write buffers | src/Storages/MergeTree/ |
| Block::cloneEmptyColumns() | 84 MB | src/Core/Block.cpp |
| ColumnString::indexImpl() | 4.6 MB | src/Columns/ColumnString.cpp |
| ApplySquashingTransform | 4.4 MB | src/Interpreters/Squashing.cpp |

## Experiment Candidates (source-level)

1. **Pre-allocate and reuse Block structure** in MergeTree write path
   - Block::cloneEmptyColumns() creates new columns every call
   - Could cache the empty block structure and reuse

2. **Reduce PODArray initial capacity** for small columns
   - PODArray grows by 2x, starting from initial_bytes
   - For columns with few rows, oversized initial allocation wastes memory

3. **Pool write buffers** in MergedBlockOutputStream
   - Each part write creates new compression buffers
   - Could pool and reuse across writes

4. **Optimize ColumnString permutation**
   - indexImpl copies all string data during permutation
   - Could use reference/view pattern for read-only access
