#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

# macOS compatibility: prefer gtimeout if timeout is not available
TIMEOUT_CMD=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || echo "")

echo "[build] Building autoopt-$TARGET:$IMAGE_TAG (local/kind)"

# Determine build mode: "source" (incremental from source) or "stock" (official image)
BUILD_MODE="${BUILD_MODE:-stock}"
if [ -f "$TARGET_DIR/Dockerfile.builder" ] && [ -d "$TARGET_DIR/src/.git" ]; then
  # If we have a builder Dockerfile and actual source, use source mode
  BUILD_MODE="${BUILD_MODE:-source}"
fi

if [ "$BUILD_MODE" = "source" ]; then
  echo "[build] Mode: source (incremental build from source)"

  BUILDER_IMAGE="autoopt-$TARGET-builder:latest"
  BUILDER_CONTAINER="autoopt-${TARGET}-builder"
  CCACHE_VOLUME="autoopt-${TARGET}-ccache"
  BUILD_VOLUME="autoopt-${TARGET}-builddir"
  OUTPUT_DIR="$TARGET_DIR/output"

  # 1. Build the builder image (only rebuilds if Dockerfile.builder changed)
  echo "[build] Ensuring builder image exists..."
  docker build \
    -t "$BUILDER_IMAGE" \
    -f "$TARGET_DIR/Dockerfile.builder" \
    "$TARGET_DIR"

  # 2. Create persistent volumes for ccache and build directory
  docker volume create "$CCACHE_VOLUME" 2>/dev/null || true
  docker volume create "$BUILD_VOLUME" 2>/dev/null || true

  # 3. Run incremental build inside builder container
  echo "[build] Running incremental build (ccache-enabled)..."
  mkdir -p "$OUTPUT_DIR"
  docker run --rm \
    -v "$TARGET_DIR/src:/src:ro" \
    -v "$CCACHE_VOLUME:/ccache" \
    -v "$BUILD_VOLUME:/build/clickhouse" \
    -v "$OUTPUT_DIR:/output" \
    "$BUILDER_IMAGE"

  # 4. Build thin runtime image with the new binary
  echo "[build] Building runtime image with custom binary..."
  docker build \
    -t "autoopt-$TARGET:$IMAGE_TAG" \
    --build-arg BUILD_MODE=source \
    -f "$TARGET_DIR/Dockerfile" \
    "$TARGET_DIR"

else
  echo "[build] Mode: stock (official image, no source changes)"
  echo "[build] Dockerfile: $TARGET_DIR/Dockerfile"
  echo "[build] Context: $TARGET_DIR/src"

  # Build using stock mode (official ClickHouse image as-is)
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "$BUILD_TIMEOUT" docker build \
      -t "autoopt-$TARGET:$IMAGE_TAG" \
      --build-arg BUILD_MODE=stock \
      -f "$TARGET_DIR/Dockerfile" \
      "$TARGET_DIR"
  else
    docker build \
      -t "autoopt-$TARGET:$IMAGE_TAG" \
      --build-arg BUILD_MODE=stock \
      -f "$TARGET_DIR/Dockerfile" \
      "$TARGET_DIR"
  fi
fi

# Load into kind cluster
echo "[build] Loading image into kind cluster..."
kind load docker-image "autoopt-$TARGET:$IMAGE_TAG" --name autoopt 2>/dev/null || \
  echo "[build] WARNING: kind load failed (cluster may not exist yet)"

echo "[build] Done. Image: autoopt-$TARGET:$IMAGE_TAG"
