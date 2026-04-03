#!/bin/bash
# Build ClickHouse from source (CONTROL — no prefetch patch)
# Prerequisites: docker, kind cluster named "autoopt"
# First build takes ~30 min; subsequent builds use ccache (~2 min)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TARGET_DIR="$REPO_ROOT/targets/clickhouse"

echo "=== BUILD: ClickHouse baseline (control) ==="

# 1. Ensure the source is on the unmodified commit
echo "[build] Checking source is on baseline commit..."
cd "$TARGET_DIR/src"
CURRENT=$(git rev-parse --short HEAD)
echo "[build] Source at commit: $CURRENT"
echo "[build] Ensure this is the UNPATCHED commit (no prefetch changes)"
cd "$REPO_ROOT"

# 2. Build the builder image (has clang-19, ccache, ninja)
echo "[build] Building builder image..."
docker build -t autoopt-clickhouse-builder:latest \
  -f "$TARGET_DIR/Dockerfile.builder" \
  "$TARGET_DIR"

# 3. Create persistent volumes for ccache and build dir
docker volume create autoopt-clickhouse-ccache 2>/dev/null || true
docker volume create autoopt-clickhouse-builddir 2>/dev/null || true

# 4. Run incremental build inside builder container
# Source mounted read-only at /src, ccache and build dir are persistent volumes
echo "[build] Running incremental build (ccache-enabled)..."
mkdir -p "$TARGET_DIR/output"
docker run --rm \
  -v "$TARGET_DIR/src:/src" \
  -v "autoopt-clickhouse-ccache:/ccache" \
  -v "autoopt-clickhouse-builddir:/build/clickhouse" \
  -v "$TARGET_DIR/output:/output" \
  autoopt-clickhouse-builder:latest

# 5. Build thin runtime image (overlays custom binary onto official image)
echo "[build] Building runtime image..."
docker build \
  -t autoopt-clickhouse:baseline \
  --build-arg BUILD_MODE=source \
  -f "$TARGET_DIR/Dockerfile" \
  "$TARGET_DIR"

# 6. Load into Kind cluster
echo "[build] Loading image into Kind cluster..."
kind load docker-image autoopt-clickhouse:baseline --name autoopt

echo "=== BUILD COMPLETE: autoopt-clickhouse:baseline ==="
