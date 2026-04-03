#!/bin/bash
# Clean up Chroma container/deployment
set -euo pipefail

MODE="${1:-docker}"  # "docker" (default) or "k8s"

echo "=== TEARDOWN: Chroma ==="

if [ "$MODE" = "k8s" ]; then
  if [ -f /tmp/autoopt-chroma-portforward.pid ]; then
    kill "$(cat /tmp/autoopt-chroma-portforward.pid)" 2>/dev/null || true
    rm -f /tmp/autoopt-chroma-portforward.pid
  fi
  ps aux | grep "port-forward.*8000" | grep -v grep | awk '{print $2}' | xargs kill 2>/dev/null || true
  kubectl --context kind-autoopt -n autoopt delete deployment autoopt-chroma 2>/dev/null || true
  kubectl --context kind-autoopt -n autoopt wait --for=delete pod \
    -l app=autoopt-chroma --timeout=60s 2>/dev/null || true
else
  docker rm -f autoopt-chroma 2>/dev/null || true
fi

echo "=== TEARDOWN COMPLETE ==="
