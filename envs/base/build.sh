#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

# macOS compatibility: prefer gtimeout if timeout is not available
TIMEOUT_CMD=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || echo "")

echo "[build] Building autoopt-$TARGET:$IMAGE_TAG"
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

# Push to remote registry
if [ "$REGISTRY" != "local" ]; then
  docker tag "autoopt-$TARGET:$IMAGE_TAG" "$REGISTRY/autoopt-$TARGET:$IMAGE_TAG"
  docker push "$REGISTRY/autoopt-$TARGET:$IMAGE_TAG"
fi

echo "[build] Done. Image: autoopt-$TARGET:$IMAGE_TAG"
