FROM rust:1.92.0 AS builder

ARG PROTOC_VERSION=31.1

WORKDIR /chroma

RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then PROTOC_ZIP=protoc-${PROTOC_VERSION}-linux-x86_64.zip; \
    elif [ "$ARCH" = "aarch64" ]; then PROTOC_ZIP=protoc-${PROTOC_VERSION}-linux-aarch_64.zip; \
    else echo "Unsupported: $ARCH" && exit 1; fi && \
    curl -OL https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/$PROTOC_ZIP && \
    unzip -o $PROTOC_ZIP -d /usr/local bin/protoc && \
    unzip -o $PROTOC_ZIP -d /usr/local 'include/*' && \
    rm -f $PROTOC_ZIP

COPY src/idl/ idl/
COPY src/Cargo.toml Cargo.toml
COPY src/Cargo.lock Cargo.lock
COPY src/rust/ rust/

ENV EXCLUDED_PACKAGES="chromadb_rust_bindings chromadb-js-bindings chroma-benchmark "

RUN --mount=type=cache,sharing=locked,target=/chroma/target/ \
    --mount=type=cache,sharing=locked,target=/usr/local/cargo/registry/ \
    --mount=type=cache,sharing=locked,target=/usr/local/cargo/git/ \
    cargo build --workspace $(printf -- '--exclude %s ' $EXCLUDED_PACKAGES) --release && \
    cp target/release/chroma /output/chroma

FROM debian:stable-slim AS runtime

RUN apt-get update && apt-get install -y dumb-init libssl-dev ca-certificates procps curl && \
    rm -rf /var/lib/apt/lists/*

COPY src/rust/frontend/sample_configs/docker_single_node.yaml /config.yaml
COPY --from=builder /output/chroma /usr/local/bin/chroma

ENV MALLOC_CONF="prof:true,prof_active:true,lg_prof_interval:30,lg_prof_sample:19"

EXPOSE 8000

ENTRYPOINT [ "dumb-init", "--", "chroma" ]
CMD [ "run", "/config.yaml" ]
