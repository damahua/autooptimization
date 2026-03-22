#!/bin/bash
set -euo pipefail

HOST="${SERVICE_HOST:-localhost}"
PORT="${SERVICE_PORT:-8123}"
BASE_URL="http://$HOST:$PORT"

echo "[clickhouse-workload] Running queries against $BASE_URL"

# Create a test table if it doesn't exist
curl -sf "$BASE_URL" --data-binary "
CREATE TABLE IF NOT EXISTS test_data (
    id UInt64,
    timestamp DateTime,
    value Float64,
    category String
) ENGINE = MergeTree()
ORDER BY (category, timestamp)
" || true

# Insert test data if table is empty
ROW_COUNT=$(curl -sf "$BASE_URL" --data-binary "SELECT count() FROM test_data FORMAT TabSeparated")
if [ "${ROW_COUNT:-0}" -lt 1000 ]; then
  echo "[clickhouse-workload] Inserting test data..."
  curl -sf "$BASE_URL" --data-binary "
  INSERT INTO test_data
  SELECT
      number AS id,
      toDateTime('2024-01-01') + number AS timestamp,
      rand() / 4294967295.0 * 100 AS value,
      arrayElement(['A','B','C','D','E'], (number % 5) + 1) AS category
  FROM numbers(100000)
  "
fi

# Run analytical queries and measure latency
TOTAL_QUERIES=0
FAILED_QUERIES=0
LATENCIES=""

QUERIES=(
  "SELECT category, avg(value), max(value), min(value) FROM test_data GROUP BY category"
  "SELECT toStartOfHour(timestamp) AS hour, count(), avg(value) FROM test_data GROUP BY hour ORDER BY hour"
  "SELECT category, quantile(0.99)(value) FROM test_data GROUP BY category"
  "SELECT * FROM test_data WHERE value > 90 ORDER BY timestamp LIMIT 100"
  "SELECT category, count(), sum(value) FROM test_data WHERE timestamp > '2024-06-01' GROUP BY category"
)

for q in "${QUERIES[@]}"; do
  for run in $(seq 1 5); do
    START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
    set +e
    curl -sf "$BASE_URL" --data-binary "$q FORMAT Null" > /dev/null 2>&1
    EXIT_CODE=$?
    set -e
    END_MS=$(python3 -c "import time; print(int(time.time()*1000))")

    LATENCY=$((END_MS - START_MS))
    TOTAL_QUERIES=$((TOTAL_QUERIES + 1))

    if [ $EXIT_CODE -ne 0 ]; then
      FAILED_QUERIES=$((FAILED_QUERIES + 1))
    else
      LATENCIES="$LATENCIES $LATENCY"
    fi
  done
done

# Compute metrics
if [ -n "$LATENCIES" ]; then
  SORTED=$(echo "$LATENCIES" | tr ' ' '\n' | sort -n | grep -v '^$')
  COUNT=$(echo "$SORTED" | wc -l | tr -d ' ')
  P99_IDX=$(echo "$COUNT * 99 / 100" | bc)
  P99_IDX=${P99_IDX:-1}
  LATENCY_P99=$(echo "$SORTED" | sed -n "${P99_IDX}p")
  P50_IDX=$(echo "$COUNT / 2" | bc)
  P50_IDX=${P50_IDX:-1}
  LATENCY_P50=$(echo "$SORTED" | sed -n "${P50_IDX}p")
else
  LATENCY_P99=0
  LATENCY_P50=0
fi

DURATION_S=${WORKLOAD_TIMEOUT:-60}
THROUGHPUT=$(echo "scale=1; $TOTAL_QUERIES / ($DURATION_S / $TOTAL_QUERIES)" | bc 2>/dev/null || echo 0)
ERROR_RATE=$(echo "scale=4; $FAILED_QUERIES / $TOTAL_QUERIES" | bc 2>/dev/null || echo 0)

# Output in standard format
echo "latency_p99_ms=${LATENCY_P99:-0}"
echo "latency_p50_ms=${LATENCY_P50:-0}"
echo "throughput_qps=${THROUGHPUT:-0}"
echo "error_rate=${ERROR_RATE}"
echo "total_requests=${TOTAL_QUERIES}"
