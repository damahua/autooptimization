#!/bin/bash
# One-time setup: create kind cluster and verify prerequisites
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Checking prerequisites ==="
for cmd in docker kubectl kind git envsubst bc curl python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "MISSING: $cmd"
    exit 1
  fi
done
echo "All tools installed."

echo ""
echo "=== Docker ==="
docker info --format 'Docker {{.ServerVersion}}' 2>/dev/null || { echo "Docker not running"; exit 1; }

echo ""
echo "=== Kind cluster ==="
if kind get clusters 2>/dev/null | grep -q "autoopt"; then
  echo "Cluster 'autoopt' already exists."
else
  echo "Creating kind cluster 'autoopt'..."
  kind create cluster --name autoopt
fi

kubectl --context kind-autoopt cluster-info | head -2

echo ""
echo "=== Setup complete ==="
echo "Run: ./demo/run.sh"
