#!/bin/bash
# Clean up ClickHouse deployment between experiments
# Each A/B comparison needs a fresh pod to avoid warm cache contamination
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TARGET_DIR="$REPO_ROOT/targets/clickhouse"

echo "=== TEARDOWN: ClickHouse ==="

# 1. Kill port-forward
if [ -f /tmp/autoopt-clickhouse-portforward.pid ]; then
  PID=$(cat /tmp/autoopt-clickhouse-portforward.pid)
  kill "$PID" 2>/dev/null || true
  rm -f /tmp/autoopt-clickhouse-portforward.pid
fi
# Also catch any stray port-forwards
ps aux | grep "port-forward.*40200" | grep -v grep | awk '{print $2}' | xargs kill 2>/dev/null || true

# 2. Delete K8s resources
kubectl --context kind-autoopt -n autoopt delete deployment autoopt-clickhouse 2>/dev/null || true
kubectl --context kind-autoopt -n autoopt delete service autoopt-clickhouse 2>/dev/null || true

# 3. Wait for pod termination
kubectl --context kind-autoopt -n autoopt wait --for=delete pod \
  -l app=autoopt-clickhouse --timeout=60s 2>/dev/null || true

echo "=== TEARDOWN COMPLETE ==="
