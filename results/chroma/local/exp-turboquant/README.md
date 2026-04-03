# exp-turboquant: TurboQuant 4-bit vector quantization (-40% peak RSS)

## Hypothesis
hnswlib stores every vector as raw float32 — 3072 bytes per 768-dim vector.
At 50K vectors, this is 146 MB just for vector data. TurboQuant (Zandieh et al.
2025) compresses each vector to 4 bits per dimension: 384 bytes + 4 bytes norm
= 388 bytes. That's 8x compression per vector.

Profile evidence: `/proc/smaps` shows 93% of RSS is anonymous heap. jemalloc
profiling confirmed 97% of memory is in hnswlib C++ (via glibc malloc), only
3% in Rust allocations. The dominant memory consumer is hnswlib vector storage.

## Code changes
Two coordinated PRs:
1. **hnswlib** (chroma-core/hnswlib#46): `turbo_quant.h` (new), modifications to
   `hnswalg.h` for quantized storage/search, `bindings.cpp` for FFI
2. **Chroma** (chroma-core/chroma#6794): `Cargo.toml` points to hnswlib fork,
   `rust/index/src/hnsw.rs` reads `CHROMA_QUANTIZATION_BITS` env var

The diff.patch contains the Chroma-side changes only (2 files).
The hnswlib changes are in the `damahua/hnswlib` fork, branch `turboquant`.

## How to reproduce
1. `./build.sh`     — build Chroma with TurboQuant hnswlib fork (~15 min)
2. `./deploy.sh`    — deploy with CHROMA_QUANTIZATION_BITS=4
3. `./workload.sh`  — same workload as baseline (50K embeddings)
4. `./collect.sh`   — collect peak RSS
5. `./teardown.sh`  — clean up

**Important:** The SAME binary is used for both baseline and experiment.
The only difference is the `CHROMA_QUANTIZATION_BITS` env var (0 vs 4).
Run baseline with deploy.sh 0, experiment with deploy.sh 4.

## Expected results
- Peak RSS: ~191 MB (baseline ~317 MB)
- Improvement: ~40% RSS reduction
- Zero errors across all API requests

## Actual results (3 runs each)
Baseline (QUANTIZATION_BITS=0): 317, 315, 318 MB → Mean 316.7 ± 1.5 MB
TurboQuant (QUANTIZATION_BITS=4): 207, 176, 190 MB → Mean 191.0 ± 15.6 MB

Decision: **KEEP** — 39.7% reduction, distributions don't overlap
PRs: https://github.com/chroma-core/hnswlib/pull/46
      https://github.com/chroma-core/chroma/pull/6794
