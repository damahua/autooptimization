#!/bin/bash
# Build Chroma from source (CONTROL — standard float32 vectors)
# Prerequisites: docker, kind cluster named "autoopt"
# First build takes ~15 min; subsequent builds use Docker layer cache
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TARGET_DIR="$REPO_ROOT/targets/chroma"

echo "=== BUILD: Chroma baseline (source, float32) ==="

# 1. Verify Chroma source exists
if [ ! -d "$TARGET_DIR/src/.git" ]; then
  echo "[build] ERROR: Chroma source not found at $TARGET_DIR/src/"
  echo "[build] Clone it: git clone --depth 1 https://github.com/chroma-core/chroma.git $TARGET_DIR/src"
  exit 1
fi

echo "[build] Chroma source at: $(cd "$TARGET_DIR/src" && git rev-parse --short HEAD)"

# 2. Build from source using Dockerfile.source
# This is a multi-stage build: rust:1.92.0 builder → debian:stable-slim runtime
# Build flags: no LTO, opt-level 1, 2 parallel jobs (to fit in 8GB RAM)
echo "[build] Building Chroma from source (this takes ~15 min first time)..."
docker build \
  -t autoopt-chroma:baseline \
  -f "$TARGET_DIR/Dockerfile.source" \
  "$TARGET_DIR"

# 3. Load into Kind cluster
echo "[build] Loading image into Kind cluster..."
kind load docker-image autoopt-chroma:baseline --name autoopt

echo "=== BUILD COMPLETE: autoopt-chroma:baseline ==="
