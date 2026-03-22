#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

echo "[deploy] Deploying autoopt-$TARGET to namespace $NAMESPACE"

# 1. Ensure namespace exists
kubectl --context "$KUBE_CONTEXT" create namespace "$NAMESPACE" 2>/dev/null || true

# 2. Apply manifests (envsubst for dynamic values)
export IMAGE_NAME="autoopt-$TARGET:$IMAGE_TAG"
envsubst < "$TARGET_DIR/k8s.yaml" | \
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" apply -f -

# 3. Wait for pod ready
echo "[deploy] Waiting for pod ready (timeout: ${DEPLOY_TIMEOUT}s)..."
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  wait --for=condition=ready pod \
  -l "app=autoopt-$TARGET" \
  --timeout="${DEPLOY_TIMEOUT}s"

# 4. Get pod name
POD=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pod -l "app=autoopt-$TARGET" -o jsonpath='{.items[0].metadata.name}')
echo "[deploy] Pod ready: $POD"

# 5. Port-forward in background
LOCAL_PORT=$(shuf -i 30000-39999 -n 1 2>/dev/null || awk 'BEGIN{srand(); print int(30000+rand()*10000)}')
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  port-forward "pod/$POD" "$LOCAL_PORT:${TARGET_SERVICE_PORT:-8080}" &
PF_PID=$!
echo "$PF_PID" > "/tmp/autoopt-$TARGET-portforward.pid"

# 6. Wait for port-forward to be ready
sleep 2
if ! kill -0 "$PF_PID" 2>/dev/null; then
  echo "[deploy] ERROR: port-forward failed"
  exit 1
fi

# 7. Write connection info for workload.sh to read
cat > "/tmp/autoopt-$TARGET-connection.env" <<EOF
SERVICE_HOST=localhost
SERVICE_PORT=$LOCAL_PORT
EOF
echo "[deploy] Service available at localhost:$LOCAL_PORT"
