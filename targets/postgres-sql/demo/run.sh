#!/bin/bash
# End-to-end SQL optimization demo
# Demonstrates the full autooptimization loop for PostgreSQL queries:
#   1. Setup schema + data
#   2. Profile (find bottlenecks)
#   3. Benchmark slow queries (baseline)
#   4. Apply optimizations (indexes + query rewrites)
#   5. Benchmark optimized queries
#   6. Compare results
#
# Usage: ./run.sh [CONNECTION_STRING]
# Default: starts a local PostgreSQL via Docker (no psql install needed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONNSTR="${1:-}"
CONTAINER_NAME="autoopt-postgres"
CLEANUP_DOCKER=false

echo "============================================"
echo "  SQL Optimization Demo (PostgreSQL)"
echo "============================================"
echo ""

# Helper: run psql (use docker exec if no local psql)
run_psql() {
  if command -v psql &>/dev/null && [ -n "$CONNSTR" ]; then
    psql "$CONNSTR" -X --pset=pager=off "$@"
  else
    docker exec -i "$CONTAINER_NAME" psql -U autoopt -d autoopt_demo -X --pset=pager=off "$@"
  fi
}

# Helper: run psql with a SQL string
run_sql() {
  echo "$1" | run_psql
}

# Helper: run psql with a file (pipe it in)
run_sql_file() {
  cat "$1" | run_psql
}

# Helper: time a query (returns ms)
time_query() {
  local query="$1"
  local result
  result=$(echo "\\timing on" | cat - <(echo "$query") | run_psql 2>&1 | grep "^Time:" | tail -1 | awk '{print $2}')
  echo "${result:-0}"
}

# Start PostgreSQL if no connection string provided
if [ -z "$CONNSTR" ]; then
  echo "=== Starting PostgreSQL via Docker ==="
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker run -d --name "$CONTAINER_NAME" \
    -p 15432:5432 \
    -e POSTGRES_DB=autoopt_demo \
    -e POSTGRES_USER=autoopt \
    -e POSTGRES_PASSWORD=autoopt \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    postgres:16 \
    -c shared_preload_libraries=pg_stat_statements \
    -c pg_stat_statements.track=all

  CLEANUP_DOCKER=true

  echo "[setup] Waiting for PostgreSQL to be ready..."
  for i in $(seq 1 30); do
    docker exec "$CONTAINER_NAME" pg_isready -U autoopt > /dev/null 2>&1 && break
    sleep 1
  done
  # Extra second for pg_stat_statements to load
  sleep 2

  run_sql "SELECT version();" 2>/dev/null | head -3 || { echo "FAILED: PostgreSQL not ready"; exit 1; }
  echo ""
fi

# ============================================
# PHASE 0: Setup
# ============================================
echo "=== PHASE 0: Setup Schema + Data ==="
echo "[setup] Creating tables and loading data (2M orders, 5M items)..."
echo "[setup] This takes ~30-60 seconds..."
run_sql_file "$SCRIPT_DIR/setup.sql" 2>&1 | tail -1
echo ""

# Reset stats
run_sql "SELECT pg_stat_reset();" > /dev/null 2>&1
run_sql "SELECT pg_stat_statements_reset();" > /dev/null 2>&1 || true

# ============================================
# PHASE 1: Profile
# ============================================
echo "=== PHASE 1: Run Queries + Profile ==="
echo "[profile] Running 5 application queries to populate stats..."
run_sql_file "$SCRIPT_DIR/slow_queries.sql" > /dev/null 2>&1
echo ""

echo "--- Missing FK Indexes (seq scans on JOINs) ---"
run_sql "
SELECT
    tc.table_name,
    kcu.column_name AS fk_column,
    ccu.table_name AS references_table,
    pg_size_pretty(pg_relation_size(tc.table_name::regclass)) AS table_size
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND NOT EXISTS (
    SELECT 1 FROM pg_indexes pi
    WHERE pi.tablename = tc.table_name
      AND pi.indexdef LIKE '%' || kcu.column_name || '%'
  )
ORDER BY pg_relation_size(tc.table_name::regclass) DESC;
"

echo ""
echo "--- Table Scan Stats ---"
run_sql "
SELECT
    relname AS table_name,
    seq_scan, idx_scan,
    CASE WHEN seq_scan + idx_scan > 0
         THEN round(100.0 * seq_scan / (seq_scan + idx_scan), 1)
         ELSE 0 END AS seq_pct,
    n_live_tup AS rows
FROM pg_stat_user_tables
WHERE n_live_tup > 0
ORDER BY seq_scan DESC;
"

# ============================================
# PHASE 3: Baseline Benchmark
# ============================================
echo ""
echo "============================================"
echo "  BASELINE: Slow Queries (no indexes)"
echo "============================================"
echo ""

# Extract queries by EXPLAIN block number
extract_query() {
  awk -v n="$1" '
    /^EXPLAIN/ { count++ }
    count == n { print }
    count == n && /;$/ { exit }
  ' "$2"
}

declare -a BASELINE_RESULTS
for q in 1 2 3 4 5; do
  QUERY=$(extract_query "$q" "$SCRIPT_DIR/slow_queries.sql")
  T1=$(time_query "$QUERY")
  T2=$(time_query "$QUERY")
  T3=$(time_query "$QUERY")
  BASELINE_RESULTS[$q]="$T1 $T2 $T3"
  echo "  Query $q baseline: ${T1}ms, ${T2}ms, ${T3}ms"
done

# ============================================
# Apply Optimizations
# ============================================
echo ""
echo "============================================"
echo "  APPLYING OPTIMIZATIONS (indexes + extensions)"
echo "============================================"
echo ""
run_sql_file "$SCRIPT_DIR/optimize.sql" 2>&1 | grep -E "^(CREATE|ANALYZE|ERROR| )" || true

# ============================================
# PHASE 3: Optimized Benchmark
# ============================================
echo ""
echo "============================================"
echo "  OPTIMIZED: Rewritten Queries (with indexes)"
echo "============================================"
echo ""

declare -a OPT_RESULTS
for q in 1 2 3 4 5; do
  QUERY=$(extract_query "$q" "$SCRIPT_DIR/optimized_queries.sql")
  T1=$(time_query "$QUERY")
  T2=$(time_query "$QUERY")
  T3=$(time_query "$QUERY")
  OPT_RESULTS[$q]="$T1 $T2 $T3"
  echo "  Query $q optimized: ${T1}ms, ${T2}ms, ${T3}ms"
done

# ============================================
# Results
# ============================================
echo ""
echo "============================================"
echo "  RESULTS"
echo "============================================"
echo ""
printf "%-8s %-30s %-30s\n" "Query" "Baseline (3 runs)" "Optimized (3 runs)"
printf "%-8s %-30s %-30s\n" "-----" "-------------------" "-------------------"
for q in 1 2 3 4 5; do
  printf "%-8s %-30s %-30s\n" "Q$q" "${BASELINE_RESULTS[$q]} ms" "${OPT_RESULTS[$q]} ms"
done

echo ""
echo "Optimizations applied:"
echo "  - FK indexes: orders.customer_id, order_items.order_id, order_items.product_id"
echo "  - Composite: orders(status, created_at) partial, orders(created_at, status)"
echo "  - Partial: customers(tier) for VIP/premium"
echo "  - Trigram: products(name) for ILIKE search"
echo "  - Covering: products(price) INCLUDE (name, stock_qty) WHERE active+stock"
echo "  - Query rewrites: subqueries → JOINs, filter-first CTEs"

echo ""
echo "Index overhead:"
run_sql "
SELECT pg_size_pretty(sum(pg_relation_size(indexname::regclass))) AS total_new_indexes
FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE 'idx_%';
"

if [ "$CLEANUP_DOCKER" = true ]; then
  echo ""
  echo "Container '$CONTAINER_NAME' still running. Cleanup: docker rm -f $CONTAINER_NAME"
fi

echo ""
echo "Done!"
