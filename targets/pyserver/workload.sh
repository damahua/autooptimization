#!/bin/bash
set -euo pipefail

HOST="${SERVICE_HOST:-localhost}"
PORT="${SERVICE_PORT:-8080}"
BASE_URL="http://$HOST:$PORT"

echo "[pyserver-workload] Running workload against $BASE_URL"

# Reset server state
curl -sf -X POST "$BASE_URL/reset" > /dev/null

TOTAL_REQUESTS=0
FAILED_REQUESTS=0
LATENCIES=""

# Phase 1: Ingest 10,000 items in batches (triggers inefficiency 1)
echo "[pyserver-workload] Phase 1: Ingesting data..."
for batch in $(seq 1 20); do
    ITEMS=$(python3 -c "import json; print(json.dumps({'items': list(range(($batch-1)*500, $batch*500))}))")

    START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
    set +e
    curl -sf -X POST -H "Content-Type: application/json" -d "$ITEMS" "$BASE_URL/ingest" > /dev/null
    EXIT_CODE=$?
    set -e
    END_MS=$(python3 -c "import time; print(int(time.time()*1000))")

    LATENCY=$((END_MS - START_MS))
    TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
    if [ $EXIT_CODE -ne 0 ]; then
        FAILED_REQUESTS=$((FAILED_REQUESTS + 1))
    else
        LATENCIES="$LATENCIES $LATENCY"
    fi
done

# Phase 2: Call /process 30 times (triggers inefficiency 2 -- unbounded history)
echo "[pyserver-workload] Phase 2: Processing (deep-copy accumulation)..."
for i in $(seq 1 30); do
    START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
    set +e
    curl -sf -X POST "$BASE_URL/process" > /dev/null
    EXIT_CODE=$?
    set -e
    END_MS=$(python3 -c "import time; print(int(time.time()*1000))")

    LATENCY=$((END_MS - START_MS))
    TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
    if [ $EXIT_CODE -ne 0 ]; then
        FAILED_REQUESTS=$((FAILED_REQUESTS + 1))
    else
        LATENCIES="$LATENCIES $LATENCY"
    fi
done

# Phase 3: Call /stats 10 times (triggers inefficiency 3)
echo "[pyserver-workload] Phase 3: Stats queries..."
for i in $(seq 1 10); do
    START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
    set +e
    curl -sf "$BASE_URL/stats" > /dev/null
    EXIT_CODE=$?
    set -e
    END_MS=$(python3 -c "import time; print(int(time.time()*1000))")

    LATENCY=$((END_MS - START_MS))
    TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
    if [ $EXIT_CODE -ne 0 ]; then
        FAILED_REQUESTS=$((FAILED_REQUESTS + 1))
    else
        LATENCIES="$LATENCIES $LATENCY"
    fi
done

# Compute metrics
if [ -n "$LATENCIES" ]; then
    SORTED=$(echo "$LATENCIES" | tr ' ' '\n' | sort -n | grep -v '^$')
    COUNT=$(echo "$SORTED" | wc -l | tr -d ' ')
    P99_IDX=$(echo "$COUNT * 99 / 100" | bc)
    P99_IDX=${P99_IDX:-1}
    [ "$P99_IDX" -lt 1 ] && P99_IDX=1
    LATENCY_P99=$(echo "$SORTED" | sed -n "${P99_IDX}p")
else
    LATENCY_P99=0
fi

ERROR_RATE=$(echo "scale=4; $FAILED_REQUESTS / $TOTAL_REQUESTS" | bc 2>/dev/null || echo 0)

echo "latency_p99_ms=${LATENCY_P99:-0}"
echo "throughput_qps=${TOTAL_REQUESTS}"
echo "error_rate=${ERROR_RATE}"
echo "total_requests=${TOTAL_REQUESTS}"
