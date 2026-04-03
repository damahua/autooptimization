#!/bin/bash
# EXAMPLE: Docker Image Build
# PURPOSE: Build a container image for a target codebase. Each target defines
#   its own Dockerfile — stock image for benchmarking, source build with debug
#   symbols for profiling (RelWithDebInfo).
# KEY PATTERNS:
#   - Timeout handling (macOS compatibility with gtimeout)
#   - Registry push for remote K8s clusters
#   - Image size tracking for build validation
# NOTE: This is a teaching example. The AI agent adapts these patterns for
#   each target rather than running this script via the dispatcher.
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
SCRIPT_NAME="build"
source "$FRAMEWORK_ROOT/examples/lifecycle/log.sh"

# macOS compatibility
TIMEOUT_CMD=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || echo "")

log_separator "BUILD: $TARGET"
log_step "BEFORE" "Image: autoopt-$TARGET:$IMAGE_TAG | Registry: $REGISTRY | Timeout: ${BUILD_TIMEOUT}s"
log_status "Dockerfile: $TARGET_DIR/Dockerfile"
log_status "Build context: $TARGET_DIR/src"

# Build image
log_status "Running docker build..."
BUILD_START=$(date +%s)
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
BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

# Push to remote registry if needed
if [ "$REGISTRY" != "local" ]; then
  log_status "Pushing to registry: $REGISTRY"
  docker tag "autoopt-$TARGET:$IMAGE_TAG" "$REGISTRY/autoopt-$TARGET:$IMAGE_TAG"
  docker push "$REGISTRY/autoopt-$TARGET:$IMAGE_TAG"
fi

IMAGE_SIZE=$(docker image inspect "autoopt-$TARGET:$IMAGE_TAG" --format '{{.Size}}' 2>/dev/null || echo "unknown")
log_step "AFTER" "Build succeeded in ${BUILD_DURATION}s | Image: autoopt-$TARGET:$IMAGE_TAG | Size: $IMAGE_SIZE bytes"
