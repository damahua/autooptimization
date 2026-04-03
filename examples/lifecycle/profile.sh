#!/bin/bash
# EXAMPLE: Profiling (Memory + CPU)
# PURPOSE: Capture profiling data from a running pod. This is the most
#   critical step — without profiling evidence, optimization is guesswork.
# KEY PATTERNS:
#   - /proc/1/smaps: per-region RSS breakdown (heap vs anon mmap vs file-backed).
#     Tells you WHERE memory lives, not just HOW MUCH. If 80% is anon_mmap,
#     the allocator uses mmap for large allocations — different strategy needed.
#   - perf record -g: CPU flame graph data (needs perf in container + privileges)
#   - Target-specific hooks (e.g., ClickHouse system.trace_log, jemalloc prof)
#     provide the richest data — always prefer native profiling tools
# NOTE: This is a teaching example. The AI agent adapts these patterns for
#   each target rather than running this script via the dispatcher.
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
RESULTS_DIR="$FRAMEWORK_ROOT/results/$TARGET/$ENV"
SCRIPT_NAME="profile"
source "$FRAMEWORK_ROOT/examples/lifecycle/log.sh"

PROFILE_LABEL="${PROFILE_LABEL:-unlabeled}"
PROFILES_DIR="$RESULTS_DIR/profiles"
mkdir -p "$PROFILES_DIR"

log_separator "PROFILE: $TARGET (label: $PROFILE_LABEL)"

if [ "${PROFILE_ENABLED:-true}" != "true" ]; then
  log_status "Profiling disabled (PROFILE_ENABLED=false)"
  exit 0
fi

POD=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pod -l "app=autoopt-$TARGET" -o jsonpath='{.items[0].metadata.name}')
log_step "BEFORE" "Pod: $POD | Label: $PROFILE_LABEL"

# === Memory profiling (always available in Linux containers) ===
if [ "${PROFILE_MEMORY:-true}" = "true" ]; then
  log_status "Capturing /proc/1/smaps (detailed memory map)..."
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    exec "$POD" -- cat /proc/1/smaps 2>/dev/null \
    > "$PROFILES_DIR/${PROFILE_LABEL}-smaps.txt" || {
    log_warn "Failed to read smaps — trying smaps_rollup..."
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
      exec "$POD" -- cat /proc/1/smaps_rollup 2>/dev/null \
      > "$PROFILES_DIR/${PROFILE_LABEL}-smaps.txt" || true
  }

  log_status "Capturing /proc/1/status..."
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    exec "$POD" -- cat /proc/1/status 2>/dev/null \
    > "$PROFILES_DIR/${PROFILE_LABEL}-status.txt" || true

  log_status "Capturing /proc/1/maps..."
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    exec "$POD" -- cat /proc/1/maps 2>/dev/null \
    > "$PROFILES_DIR/${PROFILE_LABEL}-maps.txt" || true
fi

# === CPU profiling (requires perf in container + privileges) ===
if [ "${PROFILE_CPU:-true}" = "true" ]; then
  CPU_DURATION="${PROFILE_CPU_DURATION:-30}"
  log_status "Attempting CPU profile (perf record for ${CPU_DURATION}s)..."

  # Check if perf is available in the container
  PERF_AVAIL=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    exec "$POD" -- which perf 2>/dev/null || echo "")

  if [ -n "$PERF_AVAIL" ]; then
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
      exec "$POD" -- perf record -g -p 1 --duration "$CPU_DURATION" -o /tmp/perf.data 2>/dev/null || true
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
      exec "$POD" -- perf script -i /tmp/perf.data 2>/dev/null \
      > "$PROFILES_DIR/${PROFILE_LABEL}-perf.txt" || true
    log_status "CPU profile captured"
  else
    log_warn "perf not available in container — skipping CPU profile"
  fi
fi

# === Target-specific profiling hook ===
if [ -x "$TARGET_DIR/profile.sh" ]; then
  log_status "Running target-specific profile hook..."
  if [ -f "/tmp/autoopt-$TARGET-connection.env" ]; then
    source "/tmp/autoopt-$TARGET-connection.env"
  fi
  export SERVICE_HOST="${SERVICE_HOST:-localhost}"
  export SERVICE_PORT="${SERVICE_PORT:-8080}"
  export PROFILE_LABEL PROFILES_DIR

  "$TARGET_DIR/profile.sh" > "$PROFILES_DIR/${PROFILE_LABEL}-target-profile.txt" 2>&1 || {
    log_warn "Target profile hook failed (exit $?)"
  }
  log_status "Target-specific profile saved"
fi

# Log summary of captured files
FILE_COUNT=$(ls -1 "$PROFILES_DIR/${PROFILE_LABEL}-"* 2>/dev/null | wc -l | tr -d ' ')
TOTAL_SIZE=$(du -sh "$PROFILES_DIR/${PROFILE_LABEL}-"* 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")

log_step "AFTER" "Captured $FILE_COUNT profile files (label: $PROFILE_LABEL)"
