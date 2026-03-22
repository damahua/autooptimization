#!/bin/bash
# ClickHouse profiling script — follows the target profile.sh contract.
#
# Uses ClickHouse's built-in system.trace_log (CPU + memory stack traces)
# and system.query_log (per-query metrics).
#
# Output:
#   $PROFILE_DIR/cpu.folded            — CPU folded stacks for flame graph
#   $PROFILE_DIR/memory.folded         — memory allocation folded stacks
#   $PROFILE_DIR/profiling_summary.txt — structured analysis for the agent
#
set -euo pipefail

HOST="${SERVICE_HOST:-localhost}"
PORT="${SERVICE_PORT:-8123}"
BASE_URL="http://$HOST:$PORT/?allow_introspection_functions=1"
PROFILE_DIR="${PROFILE_DIR:-.}"
PROFILE_TYPE="${PROFILE_TYPE:-both}"

echo "[clickhouse-profile] Collecting profiling data from $HOST:$PORT"

#
# 1. Folded stacks for flame graph generation
#

if [ "$PROFILE_TYPE" = "cpu" ] || [ "$PROFILE_TYPE" = "both" ]; then
  echo "[clickhouse-profile] Extracting CPU traces..."
  curl -sf "$BASE_URL" --data-binary "
  SELECT
      arrayStringConcat(arrayReverse(arrayMap(x -> demangle(addressToSymbol(x)), trace)), ';') as stack,
      count() as samples
  FROM system.trace_log
  WHERE trace_type IN ('Real', 'CPU')
    AND length(trace) > 0
  GROUP BY trace
  HAVING samples > 0
  ORDER BY samples DESC
  FORMAT TabSeparated
  " > "$PROFILE_DIR/cpu.folded" 2>/dev/null || echo "(no CPU traces)"
fi

if [ "$PROFILE_TYPE" = "memory" ] || [ "$PROFILE_TYPE" = "both" ]; then
  echo "[clickhouse-profile] Extracting memory traces..."
  curl -sf "$BASE_URL" --data-binary "
  SELECT
      arrayStringConcat(arrayReverse(arrayMap(x -> demangle(addressToSymbol(x)), trace)), ';') as stack,
      sum(abs(size)) as total_bytes
  FROM system.trace_log
  WHERE trace_type = 'Memory'
    AND length(trace) > 0
  GROUP BY trace
  HAVING total_bytes > 0
  ORDER BY total_bytes DESC
  FORMAT TabSeparated
  " > "$PROFILE_DIR/memory.folded" 2>/dev/null || echo "(no memory traces)"
fi

#
# 2. Structured profiling analysis — designed for AI agent consumption
#
echo "[clickhouse-profile] Generating profiling analysis..."
{
  echo "=== ClickHouse Profiling Analysis ==="
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Profile type: $PROFILE_TYPE"
  echo ""

  # ---------------------------------------------------------------
  # SECTION A: Memory allocation hot paths with full call chains
  # This is the most important section for memory optimization.
  # Shows WHERE memory is allocated and WHO called the allocator.
  # ---------------------------------------------------------------
  echo "================================================================"
  echo "SECTION A: MEMORY ALLOCATION HOT PATHS (call chains)"
  echo "================================================================"
  echo ""
  echo "Top allocation sites with 3-level call chain (func ← caller ← grandcaller):"
  echo "Columns: total_bytes | alloc_count | function | caller | grandcaller"
  echo ""
  curl -sf "$BASE_URL" --data-binary "
  SELECT
      sum(abs(size)) as total_bytes,
      count() as alloc_count,
      demangle(addressToSymbol(trace[1])) as func,
      if(length(trace) >= 2, demangle(addressToSymbol(trace[2])), '(root)') as caller,
      if(length(trace) >= 3, demangle(addressToSymbol(trace[3])), '(root)') as grandcaller
  FROM system.trace_log
  WHERE trace_type = 'Memory' AND length(trace) > 0
  GROUP BY func, caller, grandcaller
  ORDER BY total_bytes DESC
  LIMIT 30
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no memory trace data)"

  echo ""
  echo "Allocation size distribution (how big are individual allocations?):"
  echo "Columns: size_bucket | count | total_bytes"
  echo ""
  curl -sf "$BASE_URL" --data-binary "
  SELECT
      multiIf(
        abs(size) < 1024, '<1KB',
        abs(size) < 65536, '1KB-64KB',
        abs(size) < 1048576, '64KB-1MB',
        abs(size) < 16777216, '1MB-16MB',
        '>16MB'
      ) as size_bucket,
      count() as alloc_count,
      sum(abs(size)) as total_bytes
  FROM system.trace_log
  WHERE trace_type = 'Memory'
  GROUP BY size_bucket
  ORDER BY total_bytes DESC
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no data)"

  # ---------------------------------------------------------------
  # SECTION B: CPU hot paths with call chains
  # Shows where CPU cycles are spent (excluding idle threads).
  # ---------------------------------------------------------------
  echo ""
  echo "================================================================"
  echo "SECTION B: CPU HOT PATHS (call chains, excluding idle)"
  echo "================================================================"
  echo ""
  echo "Top CPU-consuming functions (excluding pthread_cond_wait/timedwait/sleep):"
  echo "Columns: samples | function | caller | grandcaller"
  echo ""
  curl -sf "$BASE_URL" --data-binary "
  SELECT
      count() as samples,
      demangle(addressToSymbol(trace[1])) as func,
      if(length(trace) >= 2, demangle(addressToSymbol(trace[2])), '(root)') as caller,
      if(length(trace) >= 3, demangle(addressToSymbol(trace[3])), '(root)') as grandcaller
  FROM system.trace_log
  WHERE trace_type IN ('Real', 'CPU')
    AND length(trace) > 0
    AND demangle(addressToSymbol(trace[1])) NOT LIKE '%pthread_cond%'
    AND demangle(addressToSymbol(trace[1])) NOT LIKE '%nanosleep%'
    AND demangle(addressToSymbol(trace[1])) NOT LIKE '%clock_nanosleep%'
    AND demangle(addressToSymbol(trace[1])) NOT LIKE '%epoll_wait%'
    AND demangle(addressToSymbol(trace[1])) NOT LIKE '%futex_wait%'
  GROUP BY func, caller, grandcaller
  ORDER BY samples DESC
  LIMIT 30
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no CPU data after filtering idle)"

  # ---------------------------------------------------------------
  # SECTION C: Per-query resource usage
  # Shows which query types are most expensive.
  # ---------------------------------------------------------------
  echo ""
  echo "================================================================"
  echo "SECTION C: PER-QUERY RESOURCE USAGE"
  echo "================================================================"
  echo ""
  echo "Columns: peak_memory_bytes | read_bytes | read_rows | duration_ms | query"
  echo ""
  curl -sf "$BASE_URL" --data-binary "
  SELECT
      memory_usage as peak_memory_bytes,
      read_bytes,
      read_rows,
      query_duration_ms as duration_ms,
      substring(query, 1, 120) as query
  FROM system.query_log
  WHERE type = 'QueryFinish'
    AND query NOT LIKE '%system%'
    AND event_date = today()
  ORDER BY memory_usage DESC
  LIMIT 20
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no query log data)"

  # ---------------------------------------------------------------
  # SECTION D: Server memory breakdown
  # Shows current memory state of the server.
  # ---------------------------------------------------------------
  echo ""
  echo "================================================================"
  echo "SECTION D: SERVER MEMORY STATE"
  echo "================================================================"
  echo ""
  echo "Tracked memory metrics (bytes):"
  echo "Columns: metric | value_bytes"
  echo ""
  curl -sf "$BASE_URL" --data-binary "
  SELECT metric, value
  FROM system.metrics
  WHERE metric LIKE '%Memory%' OR metric LIKE '%Cache%' OR metric LIKE '%Buffer%'
  ORDER BY value DESC
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no data)"

  echo ""
  echo "Asynchronous metrics (caches, pools):"
  echo "Columns: metric | value"
  echo ""
  curl -sf "$BASE_URL" --data-binary "
  SELECT metric, value
  FROM system.asynchronous_metrics
  WHERE metric LIKE '%Cache%' OR metric LIKE '%Pool%' OR metric LIKE '%Thread%'
    OR metric LIKE '%Memory%' OR metric LIKE '%jemalloc%'
  ORDER BY value DESC
  LIMIT 30
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no data)"

  # ---------------------------------------------------------------
  # SECTION E: Allocation patterns — repeated alloc/free cycles
  # Detects functions that allocate and free repeatedly (pooling candidates).
  # ---------------------------------------------------------------
  echo ""
  echo "================================================================"
  echo "SECTION E: ALLOCATION PATTERNS (pooling candidates)"
  echo "================================================================"
  echo ""
  echo "Functions with both allocations AND deallocations (alloc/free churn):"
  echo "Columns: alloc_count | dealloc_count | net_bytes | churn_bytes | function"
  echo ""
  curl -sf "$BASE_URL" --data-binary "
  SELECT
      countIf(size > 0) as alloc_count,
      countIf(size < 0) as dealloc_count,
      sum(size) as net_bytes,
      sum(abs(size)) as churn_bytes,
      demangle(addressToSymbol(trace[1])) as func
  FROM system.trace_log
  WHERE trace_type = 'Memory' AND length(trace) > 0
  GROUP BY func
  HAVING alloc_count > 0 AND dealloc_count > 0
  ORDER BY churn_bytes DESC
  LIMIT 20
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no data)"

} > "$PROFILE_DIR/profiling_summary.txt"

echo "[clickhouse-profile] Done. Files written to $PROFILE_DIR/"
