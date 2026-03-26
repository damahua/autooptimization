#!/bin/bash
# Phase 0 Workload: Derived from ClickHouse's own tests/performance/ suite
# Queries that stress memory through Arena/HashTable/aggregation paths
set -euo pipefail

HOST="${SERVICE_HOST:-localhost}"
PORT="${SERVICE_PORT:-8123}"
URL="http://$HOST:$PORT"

echo "[phase0] Running ClickHouse benchmark-derived workload"

# Q1: High-cardinality GROUP BY (from aggregation_external.xml)
# 10M unique keys — fits in our memory budget, exercises hash table + Arena
echo "[phase0] Q1: High-cardinality GROUP BY (10M unique keys)..."
time curl -sf "$URL" --data-binary "
SELECT number, count() FROM numbers_mt(10000000) GROUP BY number FORMAT Null
SETTINGS max_memory_usage=0, memory_profiler_step=1048576
" 2>&1

# Q2: uniqExact — hash set in Arena (from uniq_without_key.xml)
# Known to over-provision Arena (GitHub issue #7895)
echo "[phase0] Q2: uniqExact (10M unique values)..."
time curl -sf "$URL" --data-binary "
SELECT uniqExact(number) FROM numbers_mt(10000000) FORMAT Null
SETTINGS max_memory_usage=0, memory_profiler_step=1048576
" 2>&1

# Q3: String key GROUP BY (from prefetch_in_aggregation.xml)
# Variable-length Arena allocations for string keys
echo "[phase0] Q3: String GROUP BY (5M unique string keys)..."
time curl -sf "$URL" --data-binary "
SELECT toString(number) AS k, count() FROM numbers_mt(5000000) GROUP BY k FORMAT Null
SETTINGS max_memory_usage=0, memory_profiler_step=1048576
" 2>&1

# Q4: groupArray result materialization (our previous finding)
# PODArray realloc in ColumnString during convertToBlockImplFinal
echo "[phase0] Q4: groupArray with large per-key arrays..."
time curl -sf "$URL" --data-binary "
SELECT number % 1000 AS key, length(groupArray(toString(number))) AS n
FROM numbers(10000000) GROUP BY key FORMAT Null
SETTINGS max_memory_usage=0, memory_profiler_step=1048576
" 2>&1

echo "[phase0] Flushing logs..."
curl -sf "$URL" --data-binary "SYSTEM FLUSH LOGS"
sleep 2

echo "[phase0] Per-query memory from query_log:"
curl -sf "$URL" --data-binary "
SELECT
    round(memory_usage / 1048576, 1) AS peak_mb,
    query_duration_ms AS ms,
    substring(replaceAll(query, '\n', ' '), 1, 80) AS q
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query NOT LIKE '%system.%'
  AND query NOT LIKE '%SYSTEM FLUSH%'
  AND event_time > now() - INTERVAL 10 MINUTE
ORDER BY memory_usage DESC
FORMAT PrettyCompact
" 2>&1

echo "[phase0] Done."
