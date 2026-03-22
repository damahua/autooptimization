# Runtime image — thin, rebuilt each experiment.
# Takes a pre-built clickhouse binary from the builder stage.
#
# Two modes:
#   1. FROM-SOURCE mode (default): copies binary from ./output/clickhouse
#      Built by build-incremental.sh in the builder container
#   2. STOCK mode: uses official image as-is (for initial framework testing)
#      Set BUILD_MODE=stock in target.md or env

ARG BUILD_MODE=source

# --- Stock mode: use official image directly ---
FROM clickhouse/clickhouse-server:latest AS stock

# --- Source mode: overlay custom binary on official image ---
FROM clickhouse/clickhouse-server:latest AS source
# Copy the incrementally-built binary over the stock one
COPY output/clickhouse /usr/bin/clickhouse
RUN chmod +x /usr/bin/clickhouse

# --- Select final stage based on BUILD_MODE ---
FROM ${BUILD_MODE}

EXPOSE 8123 9000

HEALTHCHECK --interval=5s --timeout=3s \
  CMD wget -qO- http://localhost:8123/ping || exit 1
