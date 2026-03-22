#!/bin/bash
# Incremental build script — runs INSIDE the builder container.
# Source is mounted at /src, ccache at /ccache, output binary goes to /output.
set -euo pipefail

SRC_DIR="/src"
BUILD_DIR="/build/clickhouse"
OUTPUT_DIR="/output"

echo "[builder] Starting incremental ClickHouse build..."
echo "[builder] ccache stats before:"
ccache -s 2>/dev/null | grep "Hits\|Misses\|Size" || true

# Configure if build directory doesn't exist yet (first build)
if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
  echo "[builder] First build — running cmake configure..."
  mkdir -p "$BUILD_DIR"
  cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_LINKER=lld \
    -DENABLE_TESTS=OFF \
    -DENABLE_UTILS=OFF \
    -DENABLE_THINLTO=OFF \
    -DUSE_UNWIND=ON
fi

# Incremental build — only recompiles changed files
echo "[builder] Building clickhouse-server (incremental)..."
cmake --build "$BUILD_DIR" --target clickhouse-server -- -j$(nproc)

# Copy binary to output
echo "[builder] Copying binary to output..."
mkdir -p "$OUTPUT_DIR"
cp "$BUILD_DIR/programs/clickhouse" "$OUTPUT_DIR/clickhouse"

echo "[builder] ccache stats after:"
ccache -s 2>/dev/null | grep "Hits\|Misses\|Size" || true

echo "[builder] Done. Binary at /output/clickhouse"
