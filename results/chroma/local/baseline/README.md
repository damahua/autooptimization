# baseline: Chroma source-built (control for TurboQuant experiment)

## Hypothesis
No changes. This is the control measurement for the TurboQuant experiment.
Built from Chroma source (commit 010cd21, v1.0.12) with standard float32 vectors.

## How to reproduce
1. `./build.sh`     — build Chroma from source (~15 min first time, cached after)
2. `./deploy.sh`    — deploy to Kind cluster or run locally via Docker
3. `./workload.sh`  — insert 50K embeddings + run queries
4. `./collect.sh`   — collect peak RSS from /proc/1/status
5. `./teardown.sh`  — clean up

## Expected results
- Peak RSS: ~317 MB (50K x 768-dim embeddings, cosine similarity)
- Latency p99: ~1100ms
- Zero errors across all API requests

## Actual results

Source-built baseline (early runs, results.tsv):
Run 1: 299 MB, Run 2: 318 MB, Run 3: 317 MB → Mean: 311.3 ± 10.7 MB

TurboQuant A/B baseline (later runs, same binary as TurboQuant experiment):
Run 1: 317 MB, Run 2: 315 MB, Run 3: 318 MB → Mean: 316.7 ± 1.5 MB

Note: The TurboQuant A/B used its own baseline runs (not the earlier ones)
to ensure same-binary comparison. The 316.7 MB figure is the reference for
the 39.7% reduction claim.
