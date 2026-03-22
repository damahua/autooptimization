#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

# macOS compatibility: prefer gtimeout if timeout is not available
TIMEOUT_CMD=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || echo "")

echo "[build] Building autoopt-$TARGET:$IMAGE_TAG (local/kind)"
echo "[build] Dockerfile: $TARGET_DIR/Dockerfile"
echo "[build] Context: $TARGET_DIR/src"

# Build image with timeout (skip timeout if command not available)
if [ -n "$TIMEOUT_CMD" ]; then
  "$TIMEOUT_CMD" "$BUILD_TIMEOUT" docker build \
    -t "autoopt-$TARGET:$IMAGE_TAG" \
    -f "$TARGET_DIR/Dockerfile" \
    "$TARGET_DIR/src"
else
  docker build \
    -t "autoopt-$TARGET:$IMAGE_TAG" \
    -f "$TARGET_DIR/Dockerfile" \
    "$TARGET_DIR/src"
fi

# Load into kind cluster
echo "[build] Loading image into kind cluster..."
kind load docker-image "autoopt-$TARGET:$IMAGE_TAG" --name autoopt 2>/dev/null || \
  echo "[build] WARNING: kind load failed (cluster may not exist yet)"

echo "[build] Done. Image: autoopt-$TARGET:$IMAGE_TAG"
