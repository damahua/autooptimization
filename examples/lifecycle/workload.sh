#!/bin/bash
# EXAMPLE: Workload Runner
# PURPOSE: Run target-specific workloads N times for statistical stability.
#   A single run tells you nothing — RSS varies 10-20% between identical runs.
# KEY PATTERNS:
#   - Warmup period before measurement (avoid measuring cold-start)
#   - Health check with retry loop (service may not be ready immediately)
#   - Multi-run execution (N>=3 from program.md methodology)
#   - Timeout per run to catch hangs
# NOTE: This is a teaching example. The AI agent adapts these patterns for
#   each target rather than running this script via the dispatcher.
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
RESULTS_DIR="$FRAMEWORK_ROOT/results/$TARGET/$ENV"
SCRIPT_NAME="workload"
source "$FRAMEWORK_ROOT/examples/lifecycle/log.sh"

# macOS compatibility
TIMEOUT_CMD=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || echo "")

log_separator "WORKLOAD: $TARGET"

# 1. Read connection info
if [ -f "/tmp/autoopt-$TARGET-connection.env" ]; then
  source "/tmp/autoopt-$TARGET-connection.env"
fi
export SERVICE_HOST="${SERVICE_HOST:-localhost}"
export SERVICE_PORT="${SERVICE_PORT:-8080}"

log_step "BEFORE" "Target: $SERVICE_HOST:$SERVICE_PORT | Warmup: ${WARMUP_SECONDS}s | Runs: $WORKLOAD_RUNS | Timeout: ${WORKLOAD_TIMEOUT}s"

# 2. Warmup
log_status "Warming up for ${WARMUP_SECONDS}s..."
sleep "$WARMUP_SECONDS"

# 3. Health check
log_status "Health check (waiting up to 30s for service to respond)..."
HEALTH_CMD="until curl -sf http://$SERVICE_HOST:$SERVICE_PORT/health > /dev/null 2>&1 || nc -z $SERVICE_HOST $SERVICE_PORT 2>/dev/null; do sleep 1; done"
if [ -n "$TIMEOUT_CMD" ]; then
  HEALTH_OK=$($TIMEOUT_CMD 30 bash -c "$HEALTH_CMD" 2>/dev/null && echo yes || echo no)
else
  HEALTH_OK=$(bash -c "$HEALTH_CMD" 2>/dev/null && echo yes || echo no)
fi
if [ "$HEALTH_OK" != "yes" ]; then
  log_error "Service not responding after warmup at $SERVICE_HOST:$SERVICE_PORT"
  exit 1
fi
log_status "Health check passed"

# 4. Run workload
WORKLOAD_METRICS_FILE="$RESULTS_DIR/logs/workload-raw.log"
mkdir -p "$(dirname "$WORKLOAD_METRICS_FILE")"
> "$WORKLOAD_METRICS_FILE"

WORKLOAD_START=$(date +%s)
FAILURES=0
for i in $(seq 1 "$WORKLOAD_RUNS"); do
  log_status "Run $i/$WORKLOAD_RUNS..."
  set +e
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "$WORKLOAD_TIMEOUT" "$TARGET_DIR/workload.sh" >> "$WORKLOAD_METRICS_FILE" 2>&1
  else
    "$TARGET_DIR/workload.sh" >> "$WORKLOAD_METRICS_FILE" 2>&1
  fi
  WORKLOAD_EXIT=$?
  set -e
  if [ $WORKLOAD_EXIT -ne 0 ]; then
    log_warn "Run $i failed (exit $WORKLOAD_EXIT)"
    FAILURES=$((FAILURES + 1))
  fi
done
WORKLOAD_END=$(date +%s)
WORKLOAD_DURATION=$((WORKLOAD_END - WORKLOAD_START))

# Extract key metrics from workload output for logging
LATENCY=$(grep "latency_p99_ms=" "$WORKLOAD_METRICS_FILE" 2>/dev/null | tail -1 | cut -d= -f2 || echo "N/A")
ERRORS=$(grep "error_rate=" "$WORKLOAD_METRICS_FILE" 2>/dev/null | tail -1 | cut -d= -f2 || echo "N/A")

log_step "AFTER" "Duration: ${WORKLOAD_DURATION}s | Runs: $WORKLOAD_RUNS | Failures: $FAILURES | Latency p99: ${LATENCY}ms | Error rate: $ERRORS"
log_status "Raw results saved to $WORKLOAD_METRICS_FILE"
