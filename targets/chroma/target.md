# Target: chroma

## Source
repo: https://github.com/chroma-core/chroma
branch: main
path: targets/chroma/src

## Build
dockerfile: targets/chroma/Dockerfile
build_timeout: 900

## Primary Metric
name: peak_rss_mb
direction: lower
unit: MB

## Secondary Metrics
- query_latency_p99_ms
- insert_latency_p99_ms
- throughput_qps

## Workload
description: Vector embedding insert + similarity search + metadata filtering at scale (100K embeddings, 768-dim)
warmup: 10s
duration: 120s
script: targets/chroma/workload.sh

## Scope
editable:
  - rust/index/src/
  - rust/blockstore/src/
  - rust/cache/src/
  - rust/segment/src/
  - rust/worker/src/
  - rust/frontend/src/
  - rust/distance/src/
  - rust/types/src/

readonly:
  - rust/*/Cargo.toml
  - chromadb/ (Python layer)
  - idl/ (Protobuf definitions)

## Constraints
- query_latency_p99_ms must not increase by more than 50% from baseline
- error_rate must remain 0
- pod_restarts must remain 0

## Service
port: 8000

## Profiling
- jemalloc heap profiling: set MALLOC_CONF="prof:true,prof_active:true,lg_prof_interval:30,lg_prof_sample:19"
- Built-in pprof endpoint: /debug/pprof/heap (worker service, separate port)
- /proc/1/smaps for memory region breakdown
- /proc/1/status for VmHWM/VmRSS
