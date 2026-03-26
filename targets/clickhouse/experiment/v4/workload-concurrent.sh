#!/bin/bash
# Concurrent workload: multiple heavy queries running simultaneously
# This stresses the MemoryTracker's peak tracking under contention —
# when multiple threads realloc simultaneously, the over-counting window
# (old_size + new_size both tracked) compounds across queries.
set -euo pipefail

HOST="${SERVICE_HOST:-localhost}"
PORT="${SERVICE_PORT:-8123}"
URL="http://$HOST:$PORT"
CONCURRENT="${CONCURRENT:-4}"

echo "[concurrent] Running $CONCURRENT simultaneous heavy queries"

# Launch N concurrent GROUP BY queries
PIDS=()
for i in $(seq 1 "$CONCURRENT"); do
  curl -sf "$URL" --data-binary "
    SELECT number % 100000 AS key, count(), sum(number), avg(number)
    FROM numbers_mt(10000000)
    GROUP BY key
    FORMAT Null
    SETTINGS max_memory_usage=0, memory_profiler_step=1048576
  " &
  PIDS+=($!)
  echo "[concurrent] Launched query $i (pid ${PIDS[-1]})"
done

# Wait for all to finish
FAILURES=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    FAILURES=$((FAILURES + 1))
  fi
done

echo "[concurrent] All queries finished. Failures: $FAILURES"
sleep 1
curl -sf "$URL" --data-binary "SYSTEM FLUSH LOGS" 2>/dev/null
sleep 2

echo "[concurrent] Per-query memory (concurrent execution):"
curl -sf "$URL" --data-binary "
SELECT
    query_id,
    round(memory_usage / 1048576, 1) AS peak_mb,
    query_duration_ms AS ms,
    substring(replaceAll(query, '\n', ' '), 1, 60) AS q
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%GROUP BY key%'
  AND query NOT LIKE '%system.%'
  AND event_time > now() - INTERVAL 5 MINUTE
ORDER BY event_time DESC
LIMIT $CONCURRENT
FORMAT PrettyCompact
" 2>&1

echo "[concurrent] Server-wide peak memory:"
curl -sf "$URL" --data-binary "
SELECT
    round(value / 1048576, 1) AS server_peak_mb,
    metric
FROM system.asynchronous_metrics
WHERE metric = 'MemoryResident'
FORMAT PrettyCompact
" 2>&1

echo "error_rate=$FAILURES"
