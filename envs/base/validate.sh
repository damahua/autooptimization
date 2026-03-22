#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

echo "[validate] Running validation for $TARGET..."

# 1. Run target-specific validation if it exists
if [ -f "$TARGET_DIR/validate.sh" ]; then
  echo "[validate] Running target-specific validation..."
  set +e
  "$TARGET_DIR/validate.sh"
  VALIDATE_EXIT=$?
  set -e
  if [ $VALIDATE_EXIT -ne 0 ]; then
    echo "[validate] FAILED: target validation returned $VALIDATE_EXIT"
    exit 1
  fi
fi

# 2. Check pod health after workload
POD=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pod -l "app=autoopt-$TARGET" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$POD" ]; then
  RESTART_COUNT=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)

  if [ "$RESTART_COUNT" -gt 0 ]; then
    echo "[validate] WARNING: Pod restarted $RESTART_COUNT times during experiment"
    echo "[validate] FAILED: pod instability detected"
    exit 1
  fi

  PHASE=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

  if [ "$PHASE" != "Running" ]; then
    echo "[validate] FAILED: pod is in phase $PHASE (expected Running)"
    exit 1
  fi
fi

echo "[validate] PASSED"
