#!/bin/bash
set -euo pipefail
TARGET="$1"; shift
TAG=""
CLEAN_ALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --all) CLEAN_ALL=true; shift ;;
    *) shift ;;
  esac
done

TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
RESULTS_DIR="$FRAMEWORK_ROOT/results/$TARGET/$ENV"

echo "[cleanup] Cleaning up $TARGET (tag: ${TAG:-all}, env: $ENV)"

# 1. Teardown any running K8s resources
"$FRAMEWORK_ROOT/envs/base/teardown.sh" "$TARGET" 2>/dev/null || true

# 2. Delete experiment branches from target source repo
if [ -d "$TARGET_DIR/src/.git" ]; then
  cd "$TARGET_DIR/src"
  PATTERN="autoopt/$TARGET/${TAG:-*}"
  BRANCHES=$(git branch --list "$PATTERN" 2>/dev/null | sed 's/^[* ]*//' || echo "")
  if [ -n "$BRANCHES" ]; then
    echo "$BRANCHES" | while read -r branch; do
      echo "[cleanup] Deleting branch: $branch"
      git branch -D "$branch" 2>/dev/null || true
    done
  fi
  git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
  cd "$FRAMEWORK_ROOT"
fi

# 3. Remove Docker images
docker rmi "autoopt-$TARGET:${IMAGE_TAG:-latest}" 2>/dev/null || true

# 4. Optionally remove results
if [ "$CLEAN_ALL" = true ] && [ -d "$RESULTS_DIR" ]; then
  echo "[cleanup] Removing results: $RESULTS_DIR"
  rm -rf "$RESULTS_DIR"
fi

echo "[cleanup] Done."
