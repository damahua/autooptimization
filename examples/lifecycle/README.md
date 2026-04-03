# Lifecycle Examples

These scripts are **annotated teaching patterns**, not an automation pipeline.

## How the agent actually works

The AI agent reads `program.md` (the methodology) and executes commands directly.
These scripts show the **patterns** the agent follows — build, deploy, workload,
collect, profile, analyze, validate, teardown — but the agent adapts them to each
target rather than running them verbatim.

## Scripts

| Script | Phase | What it teaches |
|--------|-------|-----------------|
| `build.sh` | Build | Docker image creation, timeout handling, registry push |
| `build-kind.sh` | Build | Kind-specific: ccache volumes, source vs stock builds, `kind load` |
| `deploy.sh` | Deploy | K8s manifest apply, pod readiness wait, port-forward setup |
| `workload.sh` | Workload | Health check, multi-run execution, metric extraction |
| `workload-kind.sh` | Workload | Kind-specific variant with local connection handling |
| `collect.sh` | Collect | `/proc/status` VmHWM for true peak RSS, `kubectl top`, metric parsing |
| `profile.sh` | Profile | smaps memory maps, perf CPU profiles, target-specific hooks |
| `analyze.sh` | Analyze | smaps aggregation, CPU function ranking, A/B profile comparison |
| `validate.sh` | Validate | Pod health, restart detection, target-specific validation |
| `teardown.sh` | Teardown | Port-forward cleanup, K8s resource deletion |
| `log.sh` | Utility | Structured logging with timestamps and levels |
| `env.conf` | Config | Default parameter values (timeouts, resources, thresholds) |
| `env-kind.conf` | Config | Kind-specific overrides |
| `run-dispatcher.sh` | Legacy | How the env-override dispatch pattern worked (used by demo) |

## Key patterns to understand

1. **Build with debug symbols for profiling, Release for benchmarking** — `RelWithDebInfo` vs `Release`
2. **Collect `/proc/1/status` VmHWM for true peak RSS** — `kubectl top` only shows current RSS
3. **Multi-run workloads (N>=3) for statistical stability** — single runs are noise
4. **smaps breakdown** distinguishes heap vs anon mmap vs file-backed memory
5. **Target-specific profiling hooks** — ClickHouse `system.trace_log`, jemalloc `prof`, etc.
6. **Port-forward pattern** for accessing K8s pods from local tools

## Adapting for a new target

Don't copy these scripts verbatim. Read them to understand the patterns, then write
target-specific commands. For example:

- ClickHouse: use `system.trace_log` with `trace_type='Memory'` instead of generic `perf`
- Chroma: use jemalloc profiling (`_RJEM_MALLOC_CONF`) since Rust binary links jemalloc
- Any target: `/proc/1/smaps` works universally in Linux containers

See `program.md` Phase 1 for the full profiling methodology.
