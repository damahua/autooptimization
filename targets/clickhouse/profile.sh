#!/bin/bash
set -euo pipefail

HOST="${SERVICE_HOST:-localhost}"
PORT="${SERVICE_PORT:-8123}"
BASE_URL="http://$HOST:$PORT/?allow_introspection_functions=1"
PROFILE_DIR="${PROFILE_DIR:-.}"

echo "[clickhouse-profile] Collecting profiling data from $HOST:$PORT"

# 1. CPU folded stacks (for flame graph)
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

# 2. Memory folded stacks (for flame graph)
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

# 3. Generate profiling summary
echo "[clickhouse-profile] Generating profiling summary..."
{
  echo "=== ClickHouse Profiling Summary ==="
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""

  echo "--- Top CPU Functions (leaf) ---"
  curl -sf "$BASE_URL" --data-binary "
  SELECT count() as samples, demangle(addressToSymbol(trace[1])) as leaf_function
  FROM system.trace_log
  WHERE trace_type IN ('Real', 'CPU') AND length(trace) > 0
  GROUP BY leaf_function ORDER BY samples DESC LIMIT 15
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no data)"

  echo ""
  echo "--- Top Memory Allocators ---"
  curl -sf "$BASE_URL" --data-binary "
  SELECT
      sum(abs(size)) as total_bytes,
      count() as alloc_count,
      demangle(addressToSymbol(trace[1])) as func
  FROM system.trace_log
  WHERE trace_type = 'Memory' AND length(trace) > 0
  GROUP BY func ORDER BY total_bytes DESC LIMIT 15
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no data)"

  echo ""
  echo "--- Per-Query Memory Usage ---"
  curl -sf "$BASE_URL" --data-binary "
  SELECT
      substring(query, 1, 100) as query_prefix,
      max(memory_usage) as peak_memory,
      avg(query_duration_ms) as avg_ms,
      count() as executions
  FROM system.query_log
  WHERE type = 'QueryFinish' AND query NOT LIKE '%system%' AND event_date = today()
  GROUP BY query_prefix ORDER BY peak_memory DESC LIMIT 15
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no data)"

  echo ""
  echo "--- Server Memory Breakdown ---"
  curl -sf "$BASE_URL" --data-binary "
  SELECT metric, value FROM system.metrics
  WHERE metric LIKE '%Memory%' OR metric LIKE '%Cache%'
  ORDER BY value DESC LIMIT 15
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no data)"

  echo ""
  echo "--- Cache Utilization ---"
  curl -sf "$BASE_URL" --data-binary "
  SELECT metric, value FROM system.asynchronous_metrics
  WHERE metric LIKE '%Cache%' ORDER BY value DESC LIMIT 15
  FORMAT TabSeparated
  " 2>/dev/null || echo "(no data)"
} > "$PROFILE_DIR/profiling_summary.txt"

echo "[clickhouse-profile] Done. Files written to $PROFILE_DIR/"
