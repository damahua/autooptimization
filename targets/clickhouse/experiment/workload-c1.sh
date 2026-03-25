#!/bin/bash
# Targeted workload for C1: Arena allocContinue quadratic waste
# This workload creates large per-key aggregate states that force
# Arena::allocContinue to copy and abandon old memory repeatedly.
#
# Key design: 1000 keys × 50K string values per key = ~1GB aggregate state
# Each key's groupArray grows through multiple Arena chunks.
set -euo pipefail

HOST="${SERVICE_HOST:-localhost}"
PORT="${SERVICE_PORT:-8123}"
BASE_URL="http://$HOST:$PORT"

echo "[workload-c1] Targeted workload: Arena allocContinue stress test"
echo "[workload-c1] URL: $BASE_URL"

# Flush logs first
curl -sf "$BASE_URL" --data-binary "SYSTEM FLUSH LOGS" 2>/dev/null || true

# Query: groupArray with large per-key states
# 1000 keys × 50000 values/key × ~20 bytes/value = ~1GB total state
# Each key's array grows incrementally, triggering allocContinue
echo "[workload-c1] Running: groupArray with 1K keys × 50K values..."
START_MS=$(python3 -c "import time; print(int(time.time()*1000))")

curl -sf "$BASE_URL" --data-binary "
SELECT
    number % 1000 AS key,
    length(groupArray(toString(number))) AS arr_len
FROM numbers(50000000)
GROUP BY key
FORMAT Null
" 2>&1

END_MS=$(python3 -c "import time; print(int(time.time()*1000))")
LATENCY=$((END_MS - START_MS))
echo "[workload-c1] Query completed in ${LATENCY}ms"

# Collect profile data
sleep 1
curl -sf "$BASE_URL" --data-binary "SYSTEM FLUSH LOGS" 2>/dev/null || true
sleep 1

echo "[workload-c1] Arena stats from query_log:"
curl -sf "$BASE_URL" --data-binary "
SELECT
    ProfileEvents['ArenaAllocChunks'] AS arena_chunks,
    round(ProfileEvents['ArenaAllocBytes'] / 1048576, 1) AS arena_mb,
    round(memory_usage / 1048576, 1) AS peak_memory_mb,
    query_duration_ms,
    substring(replaceAll(query, '\n', ' '), 1, 80) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%groupArray(toString(number))%'
  AND query NOT LIKE '%system.query_log%'
  AND event_time > now() - INTERVAL 5 MINUTE
ORDER BY event_time DESC
LIMIT 1
FORMAT PrettyCompact
" 2>&1

# Output metrics
echo "latency_p99_ms=${LATENCY}"
echo "error_rate=0"
echo "total_requests=1"
