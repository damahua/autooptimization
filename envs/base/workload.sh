#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
RESULTS_DIR="$FRAMEWORK_ROOT/results/$TARGET/$ENV"

# 1. Read connection info from deploy output
if [ -f "/tmp/autoopt-$TARGET-connection.env" ]; then
  source "/tmp/autoopt-$TARGET-connection.env"
fi
export SERVICE_HOST="${SERVICE_HOST:-localhost}"
export SERVICE_PORT="${SERVICE_PORT:-8080}"

# 2. Warmup: wait for service to stabilize
echo "[workload] Warming up for ${WARMUP_SECONDS}s..."
sleep "$WARMUP_SECONDS"

# 3. Health check
echo "[workload] Health check..."
if ! timeout 30 bash -c "until curl -sf http://\$SERVICE_HOST:\$SERVICE_PORT/health 2>/dev/null || nc -z \$SERVICE_HOST \$SERVICE_PORT 2>/dev/null; do sleep 1; done"; then
  echo "[workload] ERROR: Service not responding after warmup"
  exit 1
fi

# 4. Run workload N times for statistical stability
echo "[workload] Running workload ($WORKLOAD_RUNS runs)..."
WORKLOAD_METRICS_FILE="$RESULTS_DIR/logs/workload-raw.log"
mkdir -p "$(dirname "$WORKLOAD_METRICS_FILE")"
> "$WORKLOAD_METRICS_FILE"

for i in $(seq 1 "$WORKLOAD_RUNS"); do
  echo "[workload] Run $i/$WORKLOAD_RUNS"
  set +e
  timeout "$WORKLOAD_TIMEOUT" "$TARGET_DIR/workload.sh" >> "$WORKLOAD_METRICS_FILE" 2>&1
  WORKLOAD_EXIT=$?
  set -e
  if [ $WORKLOAD_EXIT -ne 0 ]; then
    echo "[workload] WARNING: Run $i failed (exit $WORKLOAD_EXIT)"
  fi
done

echo "[workload] Done. Raw results in $WORKLOAD_METRICS_FILE"
