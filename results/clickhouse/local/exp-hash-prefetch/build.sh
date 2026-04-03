#!/bin/bash
# Build ClickHouse with hash prefetch patch applied
# Prerequisites: docker, kind cluster named "autoopt", baseline already built (for ccache)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TARGET_DIR="$REPO_ROOT/targets/clickhouse"

echo "=== BUILD: ClickHouse with hash prefetch patch ==="

# 1. Apply the patch to the source tree
echo "[build] Applying diff.patch to ClickHouse source..."
cd "$TARGET_DIR/src"
git checkout -- .  # Clean any previous changes
git apply "$SCRIPT_DIR/diff.patch"
echo "[build] Patch applied. Changed files:"
git diff --stat
cd "$REPO_ROOT"

# 2. Build builder image (reuses Docker cache from baseline)
echo "[build] Building builder image..."
docker build -t autoopt-clickhouse-builder:latest \
  -f "$TARGET_DIR/Dockerfile.builder" \
  "$TARGET_DIR"

# 3. Incremental build (ccache makes this fast — only recompiles changed files)
echo "[build] Running incremental build..."
mkdir -p "$TARGET_DIR/output"
docker run --rm \
  -v "$TARGET_DIR/src:/src" \
  -v "autoopt-clickhouse-ccache:/ccache" \
  -v "autoopt-clickhouse-builddir:/build/clickhouse" \
  -v "$TARGET_DIR/output:/output" \
  autoopt-clickhouse-builder:latest

# 4. Build runtime image with DIFFERENT tag
echo "[build] Building runtime image..."
docker build \
  -t autoopt-clickhouse:hash-prefetch \
  --build-arg BUILD_MODE=source \
  -f "$TARGET_DIR/Dockerfile" \
  "$TARGET_DIR"

# 5. Load into Kind
echo "[build] Loading into Kind cluster..."
kind load docker-image autoopt-clickhouse:hash-prefetch --name autoopt

# 6. Revert the patch so source tree stays clean
echo "[build] Reverting patch..."
cd "$TARGET_DIR/src"
git checkout -- .
cd "$REPO_ROOT"

echo "=== BUILD COMPLETE: autoopt-clickhouse:hash-prefetch ==="
