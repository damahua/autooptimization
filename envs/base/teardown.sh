#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
SCRIPT_NAME="teardown"
source "$FRAMEWORK_ROOT/envs/base/log.sh"

log_separator "TEARDOWN: $TARGET"
log_step "BEFORE" "Namespace: $NAMESPACE | Killing port-forwards, deleting K8s resources"

# 1. Kill port-forward
if [ -f "/tmp/autoopt-$TARGET-portforward.pid" ]; then
  PF_PID=$(cat "/tmp/autoopt-$TARGET-portforward.pid")
  log_status "Killing port-forward (PID $PF_PID)..."
  kill "$PF_PID" 2>/dev/null || true
  rm -f "/tmp/autoopt-$TARGET-portforward.pid"
fi

# 2. Delete K8s resources
log_status "Deleting K8s deployment and service..."
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  delete -f "$TARGET_DIR/k8s.yaml" --ignore-not-found --timeout=60s 2>/dev/null || true

# 3. Wait for pod termination
log_status "Waiting for pod termination..."
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  wait --for=delete pod -l "app=autoopt-$TARGET" --timeout=60s 2>/dev/null || true

# 4. Clean up connection env file
rm -f "/tmp/autoopt-$TARGET-connection.env"

log_step "AFTER" "All resources cleaned up"
