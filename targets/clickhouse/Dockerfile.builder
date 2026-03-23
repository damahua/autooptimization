# Builder image for ClickHouse — persistent, with ccache
# Source is mounted at /src, ccache volume at /ccache, output at /output.
#
# Uses ClickHouse's own build dependencies approach.
# Supports both amd64 and arm64 (Apple Silicon).

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
# Note: ClickHouse needs clang-18+ for recent versions, but clang-16 works for most
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    ccache \
    git \
    python3 \
    nasm \
    yasm \
    gawk \
    lsb-release \
    wget \
    software-properties-common \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install LLVM/Clang (use whatever version is available for this platform)
RUN wget -q https://apt.llvm.org/llvm.sh && chmod +x llvm.sh && \
    ./llvm.sh 21 all 2>/dev/null || ./llvm.sh 20 all 2>/dev/null || ./llvm.sh 19 all 2>/dev/null || ./llvm.sh 18 all 2>/dev/null && \
    rm llvm.sh && \
    CLANG_VER=$(ls /usr/bin/clang-* 2>/dev/null | grep -oP '\d+' | sort -n | tail -1) && \
    update-alternatives --install /usr/bin/clang clang /usr/bin/clang-${CLANG_VER} 100 && \
    update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-${CLANG_VER} 100 && \
    update-alternatives --install /usr/bin/lld lld /usr/bin/lld-${CLANG_VER} 100 && \
    echo "Installed clang-${CLANG_VER}"

# Configure ccache (do NOT set CC/CXX — ClickHouse's PreLoad.cmake rejects custom flags)
# Instead, use CMAKE_C_COMPILER_LAUNCHER=ccache in the build script
ENV CCACHE_DIR=/ccache
ENV CCACHE_MAXSIZE=10G
ENV CCACHE_COMPRESS=1

WORKDIR /build

# The build script run inside this container
COPY build-incremental.sh /build-incremental.sh
RUN chmod +x /build-incremental.sh

ENTRYPOINT ["/build-incremental.sh"]
