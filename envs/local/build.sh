#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

echo "[build] Building autoopt-$TARGET:$IMAGE_TAG (local/kind)"
echo "[build] Dockerfile: $TARGET_DIR/Dockerfile"
echo "[build] Context: $TARGET_DIR/src"

# Build image with timeout
timeout "$BUILD_TIMEOUT" docker build \
  -t "autoopt-$TARGET:$IMAGE_TAG" \
  -f "$TARGET_DIR/Dockerfile" \
  "$TARGET_DIR/src"

# Load into kind cluster
echo "[build] Loading image into kind cluster..."
kind load docker-image "autoopt-$TARGET:$IMAGE_TAG" --name autoopt 2>/dev/null || \
  echo "[build] WARNING: kind load failed (cluster may not exist yet)"

echo "[build] Done. Image: autoopt-$TARGET:$IMAGE_TAG"
