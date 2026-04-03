# Builder image for ClickHouse v25.8 LTS — persistent, with ccache
# This image has all build dependencies and is reused across experiments.
# Source is mounted at /src, ccache volume at /ccache, output at /output.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install base deps + clang-19 from LLVM apt repo
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    ccache \
    git \
    python3 \
    libssl-dev \
    libicu-dev \
    nasm \
    yasm \
    wget \
    software-properties-common \
    gnupg \
    && wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key > /etc/apt/trusted.gpg.d/apt.llvm.org.asc \
    && echo "deb http://apt.llvm.org/noble/ llvm-toolchain-noble-19 main" > /etc/apt/sources.list.d/llvm.list \
    && apt-get update \
    && apt-get install -y clang-19 lld-19 \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/clang clang /usr/bin/clang-19 100 \
    && update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-19 100 \
    && update-alternatives --install /usr/bin/lld lld /usr/bin/lld-19 100

# Configure ccache
ENV CCACHE_DIR=/ccache
ENV CCACHE_MAXSIZE=10G
ENV CCACHE_COMPRESS=1
ENV CC="ccache clang"
ENV CXX="ccache clang++"

WORKDIR /build

# The build script run inside this container
COPY build-incremental.sh /build-incremental.sh
RUN chmod +x /build-incremental.sh

ENTRYPOINT ["/build-incremental.sh"]
