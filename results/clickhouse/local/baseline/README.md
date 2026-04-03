# baseline: ClickHouse unmodified (control for hash prefetch experiment)

## Hypothesis
No changes. This is the control measurement for the hash prefetch experiment.
Built from the same ClickHouse commit (4a2a70d3) without the prefetch patch.

## How to reproduce
1. `./build.sh`     — build ClickHouse from source with ccache (~30 min first time, ~2 min incremental)
2. `./deploy.sh`    — deploy to Kind cluster and set up port-forward
3. `./workload.sh`  — load 10M rows + run GROUP BY benchmark (5 measured runs)
4. `./collect.sh`   — collect latency and memory metrics
5. `./teardown.sh`  — clean up K8s resources

## Expected results
- GROUP BY latency (500K string keys, 10M rows): ~136ms median
- Per-query peak memory: ~1.5 GB
- VmHWM: ~2.5 GB (includes ClickHouse base memory)

## Actual results (10 runs)
Run 1: 135ms, Run 2: 135ms, Run 3: 135ms, Run 4: 136ms, Run 5: 135ms
Run 6: 139ms, Run 7: 144ms, Run 8: 137ms, Run 9: 137ms, Run 10: 136ms
Median: 136ms (range: 135-144ms)
