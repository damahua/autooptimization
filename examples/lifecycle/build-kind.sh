#!/bin/bash
# EXAMPLE: Kind-Specific Build (Source + Stock)
# PURPOSE: Build for a local Kind cluster — supports both source builds
#   (with ccache volumes for incremental compilation) and stock image builds.
# KEY PATTERNS:
#   - ccache + Docker volumes for fast incremental C++ builds
#   - Separate builder image (Dockerfile.builder) vs runtime image (Dockerfile)
#   - kind load docker-image to push to local cluster without a registry
#   - BUILD_MODE detection: source if Dockerfile.builder + git repo exist
# NOTE: This is a teaching example. The AI agent adapts these patterns for
#   each target rather than running this script via the dispatcher.
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
SCRIPT_NAME="build-local"
source "$FRAMEWORK_ROOT/examples/lifecycle/log.sh"

# macOS compatibility
TIMEOUT_CMD=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || echo "")

log_separator "BUILD (local/kind): $TARGET"

# Determine build mode
BUILD_MODE="${BUILD_MODE:-stock}"
if [ -f "$TARGET_DIR/Dockerfile.builder" ] && [ -d "$TARGET_DIR/src/.git" ]; then
  BUILD_MODE="${BUILD_MODE:-source}"
fi

if [ "$BUILD_MODE" = "source" ]; then
  BUILDER_IMAGE="autoopt-$TARGET-builder:latest"
  CCACHE_VOLUME="autoopt-${TARGET}-ccache"
  BUILD_VOLUME="autoopt-${TARGET}-builddir"
  OUTPUT_DIR="$TARGET_DIR/output"

  log_step "BEFORE" "Mode: SOURCE | Builder: $BUILDER_IMAGE | ccache: $CCACHE_VOLUME"

  # 1. Build builder image
  log_status "Building builder image (cached if unchanged)..."
  docker build -t "$BUILDER_IMAGE" -f "$TARGET_DIR/Dockerfile.builder" "$TARGET_DIR"

  # 2. Create volumes
  docker volume create "$CCACHE_VOLUME" 2>/dev/null || true
  docker volume create "$BUILD_VOLUME" 2>/dev/null || true

  # 3. Incremental build
  log_status "Running incremental build inside builder container (ccache-enabled)..."
  BUILD_START=$(date +%s)
  mkdir -p "$OUTPUT_DIR"
  docker run --rm \
    -v "$TARGET_DIR/src:/src" \
    -v "$CCACHE_VOLUME:/ccache" \
    -v "$BUILD_VOLUME:/build/clickhouse" \
    -v "$OUTPUT_DIR:/output" \
    "$BUILDER_IMAGE"
  BUILD_END=$(date +%s)
  BUILD_DURATION=$((BUILD_END - BUILD_START))
  log_status "Source build completed in ${BUILD_DURATION}s"

  # 4. Build thin runtime image
  log_status "Building thin runtime image with custom binary..."
  docker build \
    -t "autoopt-$TARGET:$IMAGE_TAG" \
    --build-arg BUILD_MODE=source \
    -f "$TARGET_DIR/Dockerfile" \
    "$TARGET_DIR"

else
  log_step "BEFORE" "Mode: STOCK | Image: autoopt-$TARGET:$IMAGE_TAG | Timeout: ${BUILD_TIMEOUT}s"
  log_status "Building from Dockerfile (stock image)..."

  BUILD_START=$(date +%s)
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
  BUILD_END=$(date +%s)
  BUILD_DURATION=$((BUILD_END - BUILD_START))
fi

# Load into kind
log_status "Loading image into kind cluster 'autoopt'..."
kind load docker-image "autoopt-$TARGET:$IMAGE_TAG" --name autoopt 2>/dev/null || \
  log_warn "kind load failed (cluster may not exist yet)"

IMAGE_SIZE=$(docker image inspect "autoopt-$TARGET:$IMAGE_TAG" --format '{{.Size}}' 2>/dev/null || echo "unknown")
log_step "AFTER" "Build completed in ${BUILD_DURATION}s | Image: autoopt-$TARGET:$IMAGE_TAG | Size: $IMAGE_SIZE bytes | Loaded into kind"
