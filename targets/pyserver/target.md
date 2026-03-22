# Target: pyserver

## Source
repo: local
branch: main
path: targets/pyserver/src

## Build
dockerfile: targets/pyserver/Dockerfile
build_timeout: 30

## Primary Metric
name: peak_rss_mb
direction: lower
unit: MB

## Secondary Metrics
- cpu_pct
- latency_p99_ms

## Workload
description: HTTP requests triggering data processing with memory-intensive patterns
warmup: 5s
duration: 30s
script: targets/pyserver/workload.sh

## Scope
editable:
  - server.py

readonly:
  - (none)

## Constraints
- latency_p99_ms must not increase by more than 50% from baseline
- error_rate must remain 0
- pod_restarts must remain 0

## Service
port: 8080
