#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
SCRIPT_NAME="validate"
source "$FRAMEWORK_ROOT/envs/base/log.sh"

log_separator "VALIDATE: $TARGET"
log_step "BEFORE" "Checking pod health and running target-specific validation"

# 1. Run target-specific validation if it exists
if [ -f "$TARGET_DIR/validate.sh" ]; then
  log_status "Running target-specific validation: $TARGET_DIR/validate.sh"
  set +e
  "$TARGET_DIR/validate.sh"
  VALIDATE_EXIT=$?
  set -e
  if [ $VALIDATE_EXIT -ne 0 ]; then
    log_error "Target validation failed (exit $VALIDATE_EXIT)"
    log_step "AFTER" "FAILED — target validation returned $VALIDATE_EXIT"
    exit 1
  fi
  log_status "Target validation passed"
else
  log_status "No target-specific validation (targets/$TARGET/validate.sh not found)"
fi

# 2. Check pod health
POD=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pod -l "app=autoopt-$TARGET" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$POD" ]; then
  RESTART_COUNT=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)

  if [ "$RESTART_COUNT" -gt 0 ]; then
    log_error "Pod restarted $RESTART_COUNT times during experiment"
    log_step "AFTER" "FAILED — pod instability ($RESTART_COUNT restarts)"
    exit 1
  fi

  PHASE=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

  if [ "$PHASE" != "Running" ]; then
    log_error "Pod is in phase $PHASE (expected Running)"
    log_step "AFTER" "FAILED — pod phase is $PHASE"
    exit 1
  fi
  log_status "Pod $POD: phase=Running, restarts=0"
else
  log_warn "No pod found for app=autoopt-$TARGET"
fi

log_step "AFTER" "PASSED — pod healthy, no restarts"
