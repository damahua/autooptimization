#!/bin/bash
# Profile ClickHouse using built-in system.trace_log (stack-level allocation traces)
# This is the most valuable profiling data — shows exactly which functions allocate memory
# Prerequisites: ClickHouse running with memory_profiler_step > 0 (default in recent versions)
set -euo pipefail

HOST="http://localhost:40200"

echo "=== PROFILE: ClickHouse (system.trace_log) ==="

# Flush logs to capture everything
curl -sf "$HOST" --data-binary "SYSTEM FLUSH LOGS"
sleep 2

# 1. Per-query memory from query_log
echo "--- Per-Query Memory (top 20 by peak) ---"
curl -sf "$HOST" --data-binary "
SELECT
    round(memory_usage / 1048576, 1) AS peak_mb,
    read_rows,
    query_duration_ms,
    substring(replaceAll(query, '\n', ' '), 1, 80) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query NOT LIKE '%system.%'
  AND query NOT LIKE '%SYSTEM FLUSH%'
  AND event_time > now() - INTERVAL 10 MINUTE
ORDER BY memory_usage DESC
LIMIT 20
FORMAT TabSeparated
"

# 2. Memory allocation stack traces (the gold standard)
echo ""
echo "--- Memory Allocation Traces (top 20 by bytes) ---"
curl -sf "$HOST/?allow_introspection_functions=1" --data-binary "
SELECT
    count() AS alloc_count,
    round(sum(abs(size)) / 1048576, 1) AS total_mb,
    arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), arrayReverse(trace)), ' <- ') AS stack_trace
FROM system.trace_log
WHERE trace_type = 'Memory'
  AND event_time > now() - INTERVAL 10 MINUTE
GROUP BY trace
ORDER BY sum(abs(size)) DESC
LIMIT 20
FORMAT TabSeparated
" 2>/dev/null || echo "(trace_log not available — needs memory_profiler_step > 0)"

# 3. CPU traces
echo ""
echo "--- CPU Traces (top 20 functions by samples) ---"
curl -sf "$HOST/?allow_introspection_functions=1" --data-binary "
SELECT
    count() AS samples,
    arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), arrayReverse(trace)), ' <- ') AS stack_trace
FROM system.trace_log
WHERE trace_type = 'CPU'
  AND event_time > now() - INTERVAL 10 MINUTE
GROUP BY trace
ORDER BY count() DESC
LIMIT 20
FORMAT TabSeparated
" 2>/dev/null || echo "(CPU traces not available)"

# 4. ProfileEvents (aggregation-specific)
echo ""
echo "--- ProfileEvents (aggregation-related) ---"
curl -sf "$HOST" --data-binary "
SELECT
    round(memory_usage / 1048576, 1) AS peak_mb,
    ProfileEvents['ArenaAllocChunks'] AS arena_chunks,
    round(ProfileEvents['ArenaAllocBytes'] / 1048576, 1) AS arena_mb,
    ProfileEvents['AggregationPreallocatedElementsInHashTables'] AS prealloc,
    query_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%GROUP BY%'
  AND query NOT LIKE '%system.%'
  AND event_time > now() - INTERVAL 10 MINUTE
ORDER BY memory_usage DESC
LIMIT 10
FORMAT TabSeparated
"

echo "=== PROFILE COMPLETE ==="
