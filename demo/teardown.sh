#!/bin/bash
# Clean up demo: teardown K8s resources, optionally delete kind cluster
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Tearing down demo ==="

# Teardown any running pods
export WARMUP_SECONDS=5 WORKLOAD_RUNS=1 RESOURCE_LIMITS_MEMORY=512Mi RESOURCE_REQUESTS_MEMORY=256Mi
./run.sh local teardown.sh pyserver 2>/dev/null || true

# Clean results
rm -rf results/pyserver/
echo "Results cleaned."

# Reset source branches
if [ -d "targets/pyserver/src/.git" ]; then
  cd targets/pyserver/src
  FIRST_COMMIT=$(git rev-list --max-parents=0 HEAD)
  git checkout -f "$FIRST_COMMIT" 2>/dev/null || true
  git branch --list 'autoopt/*' 2>/dev/null | sed 's/^[* ]*//' | while read -r b; do
    git branch -D "$b" 2>/dev/null || true
  done
  git checkout -B main 2>/dev/null || true
  cd - > /dev/null
  echo "Source branches cleaned."
fi

echo ""
if [ "${1:-}" = "--delete-cluster" ]; then
  echo "Deleting kind cluster..."
  kind delete cluster --name autoopt
  echo "Cluster deleted."
else
  echo "Kind cluster 'autoopt' preserved. Pass --delete-cluster to remove it."
fi

echo "Teardown complete."
