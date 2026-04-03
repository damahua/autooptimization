#!/bin/bash
# Benchmark workload: high-cardinality string GROUP BY
# Deterministic data (sipHash64), 10M rows, 500K unique string keys
# 3 warmup runs + 5 measured runs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST="http://localhost:40200"

echo "=== WORKLOAD: ClickHouse GROUP BY benchmark ==="

# 1. Create table and load deterministic data
echo "[workload] Creating table and loading 10M rows..."
curl -sf "$HOST" --data-binary "
CREATE TABLE IF NOT EXISTS agg_data (
  id UInt64,
  key_high_card String,
  key_med_card String,
  key_low_card LowCardinality(String),
  int_val UInt64,
  float_val Float64,
  str_val String,
  ts DateTime
) ENGINE = MergeTree() ORDER BY (id)"

curl -sf "$HOST" --data-binary "
INSERT INTO agg_data
SELECT
  number,
  toString(sipHash64(number) % 500000),
  toString(sipHash64(number+1) % 1000),
  toString(sipHash64(number+2) % 10),
  sipHash64(number+3),
  reinterpretAsFloat64(sipHash64(number+4)),
  concat('val_', toString(sipHash64(number+5) % 100000)),
  toDateTime('2024-01-01') + toIntervalSecond(number)
FROM numbers(10000000)"
echo "[workload] Data loaded: 10M rows, 500K unique string keys"

# 2. Warmup (3 runs — also populates hash table stats cache)
echo "[workload] Warmup (3 runs)..."
for i in 1 2 3; do
  curl -sf "$HOST" --data-binary "SELECT key_high_card, count(), sum(int_val), avg(float_val) FROM agg_data GROUP BY key_high_card FORMAT Null" > /dev/null
done

# 3. Flush old traces
curl -sf "$HOST" --data-binary "SYSTEM FLUSH LOGS"
sleep 2

# 4. Measured runs
echo "[workload] Benchmark (5 measured runs)..."
for run in $(seq 1 5); do
  START=$(python3 -c "import time; print(int(time.time()*1000))")
  curl -sf "$HOST" --data-binary "SELECT key_high_card, count(), sum(int_val), avg(float_val) FROM agg_data GROUP BY key_high_card FORMAT Null" > /dev/null
  END=$(python3 -c "import time; print(int(time.time()*1000))")
  LATENCY=$((END - START))
  echo "  run $run: ${LATENCY}ms"
  echo "run_${run}_latency_ms=$LATENCY" >> "$SCRIPT_DIR/metrics.log"
done

# 5. Regression checks (medium and low cardinality)
echo "[workload] Regression checks..."
START=$(python3 -c "import time; print(int(time.time()*1000))")
curl -sf "$HOST" --data-binary "SELECT key_med_card, count(), sum(int_val), avg(float_val) FROM agg_data GROUP BY key_med_card FORMAT Null" > /dev/null
END=$(python3 -c "import time; print(int(time.time()*1000))")
echo "  1K keys: $((END - START))ms"

START=$(python3 -c "import time; print(int(time.time()*1000))")
curl -sf "$HOST" --data-binary "SELECT str_val, count() FROM agg_data GROUP BY str_val FORMAT Null" > /dev/null
END=$(python3 -c "import time; print(int(time.time()*1000))")
echo "  100K keys: $((END - START))ms"

echo "=== WORKLOAD COMPLETE ==="
