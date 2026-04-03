#!/bin/bash
# Build Chroma with TurboQuant hnswlib fork
# This build uses Dockerfile.turboquant which points to damahua/hnswlib@turboquant
# Prerequisites: docker, Chroma source with turboquant branch checked out
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TARGET_DIR="$REPO_ROOT/targets/chroma"

echo "=== BUILD: Chroma with TurboQuant ==="

# 1. Verify source is on turboquant branch
echo "[build] Checking Chroma source..."
cd "$TARGET_DIR/src"
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
echo "[build] Current branch: $CURRENT_BRANCH"

# The turboquant branch has Cargo.toml pointing to damahua/hnswlib fork
# and the CHROMA_QUANTIZATION_BITS env var reading in hnsw.rs
if [ "$CURRENT_BRANCH" != "autoopt/turboquant" ]; then
  echo "[build] Switching to autoopt/turboquant branch..."
  git checkout autoopt/turboquant 2>/dev/null || {
    echo "[build] ERROR: autoopt/turboquant branch not found."
    echo "[build] Create it by applying the Cargo.toml + hnsw.rs changes from chroma PR #6794"
    exit 1
  }
fi
cd "$REPO_ROOT"

# 2. Build with Dockerfile.turboquant
# This Dockerfile also copies hnswlib-patched/ into the build context
echo "[build] Building Chroma with TurboQuant (this takes ~15 min first time)..."
docker build \
  -t autoopt-chroma:turboquant \
  -f "$TARGET_DIR/Dockerfile.turboquant" \
  "$TARGET_DIR"

# 3. Load into Kind (if using K8s)
echo "[build] Loading image into Kind cluster..."
kind load docker-image autoopt-chroma:turboquant --name autoopt 2>/dev/null || true

echo "=== BUILD COMPLETE: autoopt-chroma:turboquant ==="
echo ""
echo "This image supports both float32 and TurboQuant modes:"
echo "  CHROMA_QUANTIZATION_BITS=0  → standard float32 (control)"
echo "  CHROMA_QUANTIZATION_BITS=4  → TurboQuant 4-bit (experiment)"
