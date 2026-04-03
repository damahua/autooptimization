#!/bin/bash
# Collect metrics from ClickHouse pod after workload
# Key metric: VmHWM (true peak RSS from /proc/1/status)
set -euo pipefail

HOST="http://localhost:40200"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== COLLECT: ClickHouse metrics ==="

POD=$(kubectl --context kind-autoopt -n autoopt get pod -l app=autoopt-clickhouse \
  -o jsonpath='{.items[0].metadata.name}')

# 1. Peak RSS from /proc/1/status (the TRUE peak, not current)
echo "[collect] Reading /proc/1/status..."
kubectl --context kind-autoopt -n autoopt exec "$POD" -- cat /proc/1/status | grep -E "^Vm(RSS|HWM|Peak|Size)"

# 2. Flush logs and get per-query metrics from ClickHouse
curl -sf "$HOST" --data-binary "SYSTEM FLUSH LOGS"
sleep 2

echo ""
echo "[collect] Per-query memory (last 5 GROUP BY queries):"
curl -sf "$HOST" --data-binary "
SELECT
    round(memory_usage / 1048576, 1) AS peak_mb,
    query_duration_ms,
    ProfileEvents['AggregationPreallocatedElementsInHashTables'] AS prealloc
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%key_high_card%GROUP BY%'
  AND query NOT LIKE '%system.%'
  AND event_time > now() - INTERVAL 5 MINUTE
ORDER BY event_time DESC
LIMIT 5
FORMAT PrettyCompact
"

echo ""
echo "[collect] Memory allocation traces (top 10 by bytes):"
curl -sf "$HOST/?allow_introspection_functions=1" --data-binary "
SELECT
    count() AS alloc_count,
    round(sum(abs(size)) / 1048576, 1) AS total_mb,
    arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), arrayReverse(trace)), ' <- ') AS stack
FROM system.trace_log
WHERE trace_type = 'Memory'
  AND event_time > now() - INTERVAL 5 MINUTE
GROUP BY trace
ORDER BY sum(abs(size)) DESC
LIMIT 10
FORMAT TabSeparated
" 2>/dev/null || echo "(trace_log not available)"

# 3. Pod health
RESTARTS=$(kubectl --context kind-autoopt -n autoopt get pod "$POD" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}')
echo ""
echo "[collect] Pod restarts: $RESTARTS"
[ "$RESTARTS" -eq 0 ] || echo "WARNING: Pod restarted during experiment!"

echo "=== COLLECT COMPLETE ==="
