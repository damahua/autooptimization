# Builder image for ClickHouse — persistent, with ccache
# This image has all build dependencies and is reused across experiments.
# Source is mounted at /src, ccache volume at /ccache, output at /output.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    clang-16 \
    lld-16 \
    ccache \
    git \
    python3 \
    libssl-dev \
    libicu-dev \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/clang clang /usr/bin/clang-16 100 \
    && update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-16 100 \
    && update-alternatives --install /usr/bin/lld lld /usr/bin/lld-16 100

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
