#!/bin/bash
# Deploy ClickHouse with hash prefetch patch to Kind cluster
# Same as baseline deploy but uses the patched image
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TARGET_DIR="$REPO_ROOT/targets/clickhouse"
PORT=40200

echo "=== DEPLOY: ClickHouse hash-prefetch ==="

# 1. Clean up previous deployment
echo "[deploy] Cleaning previous deployment..."
ps aux | grep "port-forward.*40200" | grep -v grep | awk '{print $2}' | xargs kill 2>/dev/null || true
kubectl --context kind-autoopt -n autoopt delete deployment autoopt-clickhouse 2>/dev/null || true
kubectl --context kind-autoopt -n autoopt wait --for=delete pod -l app=autoopt-clickhouse --timeout=60s 2>/dev/null || true

# 2. Create namespace
kubectl --context kind-autoopt create namespace autoopt 2>/dev/null || true

# 3. Deploy with EXPERIMENT image
echo "[deploy] Deploying with hash-prefetch image..."
export IMAGE_NAME="autoopt-clickhouse:hash-prefetch"
export RESOURCE_REQUESTS_CPU="1"
export RESOURCE_REQUESTS_MEMORY="4Gi"
export RESOURCE_LIMITS_CPU="4"
export RESOURCE_LIMITS_MEMORY="8Gi"
envsubst < "$TARGET_DIR/k8s.yaml" | kubectl --context kind-autoopt -n autoopt apply -f -

# 4. Wait for ready
echo "[deploy] Waiting for pod readiness..."
kubectl --context kind-autoopt -n autoopt wait --for=condition=ready pod \
  -l app=autoopt-clickhouse --timeout=120s

# 5. Port-forward
POD=$(kubectl --context kind-autoopt -n autoopt get pod -l app=autoopt-clickhouse \
  -o jsonpath='{.items[0].metadata.name}')
echo "[deploy] Port-forwarding $POD:8123 -> localhost:$PORT"
kubectl --context kind-autoopt -n autoopt port-forward "pod/$POD" "$PORT:8123" &
PF_PID=$!
echo "$PF_PID" > /tmp/autoopt-clickhouse-portforward.pid
sleep 3

curl -sf "http://localhost:$PORT/ping" || { echo "[deploy] FAILED"; exit 1; }

echo "=== DEPLOY COMPLETE: localhost:$PORT (PID $PF_PID) ==="
