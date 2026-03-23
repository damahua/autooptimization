#!/bin/bash
# Incremental build script — runs INSIDE the builder container.
# Source is mounted at /src, ccache at /ccache, output binary goes to /output.
set -euo pipefail

SRC_DIR="/src"
BUILD_DIR="/build/clickhouse"
OUTPUT_DIR="/output"
NPROC=$(nproc)

# Use fewer parallel jobs if memory is limited (each clang instance uses ~1-2GB)
MAX_JOBS=$((NPROC > 8 ? 8 : NPROC))

# ClickHouse's PreLoad.cmake rejects custom CC/CXX/CFLAGS — must be totally clean
unset CC CXX CFLAGS CXXFLAGS LDFLAGS CMAKE_C_FLAGS CMAKE_CXX_FLAGS 2>/dev/null || true
export CC=""
export CXX=""
export CFLAGS=""
export CXXFLAGS=""
export LDFLAGS=""

echo "[builder] ClickHouse incremental build"
echo "[builder] CPUs: $NPROC, max parallel jobs: $MAX_JOBS"
echo "[builder] ccache stats before:"
ccache -s 2>/dev/null | grep -E "Hits|Misses|Cache size" || true

# Configure if build directory doesn't exist yet (first build)
if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
  echo "[builder] First build — running cmake configure..."
  echo "[builder] Env check: CC='$CC' CXX='$CXX' CFLAGS='$CFLAGS' LDFLAGS='$LDFLAGS'"
  mkdir -p "$BUILD_DIR"
  # Let ClickHouse's PreLoad.cmake auto-detect clang and set toolchain
  # Only pass minimal flags that PreLoad.cmake allows
  cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DENABLE_TESTS=OFF \
    -DENABLE_UTILS=OFF \
    -DENABLE_THINLTO=OFF \
    -DENABLE_LIBRARIES=OFF \
    -DENABLE_ODBC=OFF \
    -DENABLE_GRPC=OFF \
    -DENABLE_KAFKA=OFF \
    -DENABLE_NATS=OFF \
    -DENABLE_RABBITMQ=OFF \
    -DENABLE_HDFS=OFF \
    -DENABLE_S3=OFF \
    -DENABLE_AZURE_BLOB_STORAGE=OFF \
    -DENABLE_EMBEDDED_COMPILER=OFF
fi

# Incremental build — only recompiles changed files
echo "[builder] Building clickhouse (incremental, -j$MAX_JOBS)..."
cmake --build "$BUILD_DIR" --target clickhouse -- -j"$MAX_JOBS"

# Copy binary to output
echo "[builder] Copying binary to output..."
mkdir -p "$OUTPUT_DIR"
cp "$BUILD_DIR/programs/clickhouse" "$OUTPUT_DIR/clickhouse"
chmod +x "$OUTPUT_DIR/clickhouse"

echo "[builder] Binary size: $(du -h "$OUTPUT_DIR/clickhouse" | cut -f1)"
echo "[builder] ccache stats after:"
ccache -s 2>/dev/null | grep -E "Hits|Misses|Cache size" || true
echo "[builder] Done."
