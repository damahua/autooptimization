#!/bin/bash
# Deploy Chroma baseline to Kind cluster (or run locally via Docker)
# Prerequisites: image built via build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TARGET_DIR="$REPO_ROOT/targets/chroma"
PORT=8000
MODE="${1:-docker}"  # "docker" (default) or "k8s"

echo "=== DEPLOY: Chroma baseline (mode: $MODE) ==="

if [ "$MODE" = "k8s" ]; then
  # K8s deployment
  ps aux | grep "port-forward.*8000" | grep -v grep | awk '{print $2}' | xargs kill 2>/dev/null || true
  kubectl --context kind-autoopt -n autoopt delete deployment autoopt-chroma 2>/dev/null || true
  kubectl --context kind-autoopt -n autoopt wait --for=delete pod -l app=autoopt-chroma --timeout=60s 2>/dev/null || true

  kubectl --context kind-autoopt create namespace autoopt 2>/dev/null || true

  export IMAGE_NAME="autoopt-chroma:baseline"
  export RESOURCE_REQUESTS_CPU="1"
  export RESOURCE_REQUESTS_MEMORY="2Gi"
  export RESOURCE_LIMITS_CPU="2"
  export RESOURCE_LIMITS_MEMORY="4Gi"

  envsubst < "$TARGET_DIR/k8s.yaml" | kubectl --context kind-autoopt -n autoopt apply -f -

  kubectl --context kind-autoopt -n autoopt wait --for=condition=ready pod \
    -l app=autoopt-chroma --timeout=120s

  POD=$(kubectl --context kind-autoopt -n autoopt get pod -l app=autoopt-chroma \
    -o jsonpath='{.items[0].metadata.name}')
  kubectl --context kind-autoopt -n autoopt port-forward "pod/$POD" "$PORT:8000" &
  echo $! > /tmp/autoopt-chroma-portforward.pid
  sleep 3
else
  # Docker deployment (simpler, recommended for reproduction)
  echo "[deploy] Stopping previous container..."
  docker rm -f autoopt-chroma 2>/dev/null || true

  echo "[deploy] Starting Chroma container..."
  docker run -d --name autoopt-chroma \
    -p "$PORT:8000" \
    -e IS_PERSISTENT=1 \
    -e ANONYMIZED_TELEMETRY=FALSE \
    autoopt-chroma:baseline

  echo "[deploy] Waiting for service to be ready..."
  for i in $(seq 1 30); do
    curl -sf "http://localhost:$PORT/api/v2/heartbeat" > /dev/null 2>&1 && break
    sleep 1
  done
fi

# Health check
curl -sf "http://localhost:$PORT/api/v2/heartbeat" || { echo "[deploy] FAILED"; exit 1; }
echo "=== DEPLOY COMPLETE: localhost:$PORT ==="
