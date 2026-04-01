# TurboQuant for Chroma Single-Node HNSW

**Date:** 2026-03-31
**Target:** chroma-core/hnswlib fork + Chroma Rust FFI
**Goal:** Reduce peak_rss_mb by ~130 MB (85% vector storage reduction) via 4-bit TurboQuant quantization

## Background

Chroma's single-node HNSW stores 768-dim float32 vectors at 3072 bytes each in hnswlib's
`data_level0_memory_`. For 50K vectors this consumes 160 MB — 97% of total memory growth.
The hnswlib C++ code uses glibc malloc directly (not jemalloc), confirmed by profiling.

TurboQuant (Zandieh et al. 2025) is a data-oblivious scalar quantizer that:
- Applies a random rotation to make coordinates near-independent
- Quantizes each coordinate with an optimal Lloyd-Max codebook
- Achieves near-Shannon-optimal distortion at any bit-width
- Requires zero training/preprocessing (online, O(1) per vector)

## Components

### 1. turbo_quant.h — Quantizer (C++)

- Random rotation matrix generated from seed (deterministic, reproducible)
  - Use fast structured rotation: Π = HD where H=Hadamard, D=random sign diagonal
  - O(d log d) rotation vs O(d²) for dense matrix — critical for 768-dim
- Pre-computed Lloyd-Max codebook centroids for b=4 bits (16 levels)
  - Centroids for Beta distribution on unit sphere, stored as const float[16]
  - At d=768, distribution ≈ N(0, 1/d), centroids are symmetric around 0
- `void quantize(const float* input, uint8_t* output, int dim, const float* rotation_signs, float* norm_out)`
- `void dequantize(const uint8_t* codes, float* output, int dim, const float* rotation_signs, float norm)`

### 2. space_turbo_quant.h — Asymmetric Distance (C++)

- Query vector: rotated float32 (not quantized)
- Database vector: 4-bit codes (2 codes per byte)
- Distance computation: for each coordinate, lookup centroid from code, subtract from query coord, square, sum
- L2 distance: Σ(q_rotated[i] - centroid[code[i]])²
- Cosine distance: reconstruct via norms + L2 relationship
- SIMD: process 32 coordinates per AVX2 iteration (16 bytes = 32 4-bit codes)

### 3. HNSW Integration (hnswalg.h modifications)

- New field: `int quantization_bits_` (0, 2, 3, or 4)
- New field: `float* rotation_signs_` (random ±1 diagonal, dim floats)
- New field: `float* codebook_` (2^b centroid values)
- Modified `data_size_` calculation: `quantization_bits_ > 0 ? ceil(dim * bits / 8) + sizeof(float) : dim * sizeof(float)`
- `addPoint`: rotate + quantize before memcpy (norm stored inline after codes)
- `searchBaseLayerST`: uses TurboQuant asymmetric distance function
- `get()`: dequantize codes → inverse rotate → return float32
- Header serialization: store quantization_bits_, rotation seed, codebook

### 4. Rust FFI (bindings.cpp + hnsw.rs)

- `create_index_quantized(space, dim, quantization_bits)` → Index*
- Existing `add_item(index, float* data, label)` unchanged — quantization happens inside C++
- Existing `knn_query(index, float* query, k, ...)` unchanged — asymmetric distance inside C++
- New: `get_item_dequantized(index, label, float* output)` for returning approximate float32

### 5. Chroma Integration (Rust)

- `HnswIndexConfig` gains `quantization_bits: usize` field (default 0)
- `local_hnsw.rs`: pass quantization_bits to hnswlib init
- Collection metadata: `"hnsw:quantization_bits": 4`
- No changes to Python API, query API, or record segment

## Memory Layout

```
Current (float32):     [links:132][vector:3072][label:8] = 3212 bytes/element
TurboQuant 4-bit:      [links:132][codes:384][norm:4][label:8] = 528 bytes/element

50K elements: 160 MB → 26 MB (134 MB savings, 6.1x compression)
```

## Dataset & Verification

### Memory Benchmark (framework compliance)
- Same workload: 50K × 768-dim deterministic embeddings, cosine similarity
- N>=3 runs each for baseline and experiment
- Primary metric: peak_rss_mb
- Expected: ~310 MB → ~180 MB (130 MB reduction)

### Recall Benchmark
- DBpedia entities (1536-dim, OpenAI embeddings) from HuggingFace — or —
- Synthetic normalized vectors with known ground truth
- Measure: recall@10 for exact float32 vs TurboQuant 4-bit
- Acceptance: recall@10 >= 0.95 (per paper's results)

### Correctness Tests
- Quantize/dequantize round-trip MSE matches paper's bounds
- Distance function: TurboQuant distance ranks match exact distance ranks for >95% of queries
- Serialization: save + load preserves quantized index correctly

## Out of Scope

- TurboQuant_prod (QJL residual for unbiased inner product) — MSE variant sufficient for cosine/L2
- Entropy encoding of codebook indices
- GPU acceleration
- Changes to Chroma Python API or distributed SPANN path
- Bit-widths other than 4 (can add 2, 3 later)
