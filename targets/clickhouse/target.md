# Target: ClickHouse

## Source
repo: https://github.com/ClickHouse/ClickHouse
branch: master
path: targets/clickhouse/src

## Build
dockerfile: targets/clickhouse/Dockerfile
build_timeout: 600

## Primary Metric
name: peak_rss_mb
direction: lower
unit: MB

## Secondary Metrics
- cpu_pct
- latency_p99_ms
- throughput_qps

## Workload
description: Run analytical queries against single-node ClickHouse
warmup: 30s
duration: 120s
script: targets/clickhouse/workload.sh

## Scope
editable:
  - src/Storages/MergeTree/
  - src/Common/Allocator*
  - src/Interpreters/
  - src/Processors/

readonly:
  - src/Client/
  - tests/

## Constraints
- latency_p99_ms must not increase by more than 10% from baseline
- error_rate must remain 0

## Service
port: 8123
