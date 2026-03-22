#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

echo "[build] Building autoopt-$TARGET:$IMAGE_TAG"
echo "[build] Dockerfile: $TARGET_DIR/Dockerfile"
echo "[build] Context: $TARGET_DIR/src"

# Build image with timeout
timeout "$BUILD_TIMEOUT" docker build \
  -t "autoopt-$TARGET:$IMAGE_TAG" \
  -f "$TARGET_DIR/Dockerfile" \
  "$TARGET_DIR/src"

# Push to remote registry
if [ "$REGISTRY" != "local" ]; then
  docker tag "autoopt-$TARGET:$IMAGE_TAG" "$REGISTRY/autoopt-$TARGET:$IMAGE_TAG"
  docker push "$REGISTRY/autoopt-$TARGET:$IMAGE_TAG"
fi

echo "[build] Done. Image: autoopt-$TARGET:$IMAGE_TAG"
