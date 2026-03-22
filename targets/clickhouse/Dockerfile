# For initial framework testing: use official ClickHouse image
# When optimizing source code, replace with a build-from-source Dockerfile
FROM clickhouse/clickhouse-server:latest

# Expose HTTP and native ports
EXPOSE 8123 9000

# Health check
HEALTHCHECK --interval=5s --timeout=3s \
  CMD wget -qO- http://localhost:8123/ping || exit 1
