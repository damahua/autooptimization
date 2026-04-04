#!/bin/bash
# Head-to-head: PostgreSQL vs ClickHouse for 5-table analytical JOINs
# Tests 5 approaches with the same data and query:
#   1. PostgreSQL raw (5-table JOIN with FK indexes)
#   2. PostgreSQL + daily materialized view
#   3. ClickHouse normalized (5-table JOIN, columnar engine)
#   4. ClickHouse dictGet() (1 JOIN + in-memory lookups)
#   5. ClickHouse denormalized (flat table, zero JOINs)
#
# Usage: ./run.sh
# Requires: docker
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../../../results/postgres-vs-clickhouse"
mkdir -p "$RESULTS_DIR"
RESULTS_FILE="$RESULTS_DIR/benchmark-results.txt"

PG_CONTAINER="autoopt-pg-bench"
CH_CONTAINER="autoopt-ch-bench"
RUNS=5

pg() { docker exec -i "$PG_CONTAINER" psql -U autoopt -d autoopt_demo -X --pset=pager=off "$@"; }
ch() { curl -sf "http://localhost:18123/?user=autoopt&password=autoopt" --data-binary "$1"; }
ch_time() { curl -sf -w '%{time_total}' "http://localhost:18123/?user=autoopt&password=autoopt" --data-binary "$1" -o /dev/null; }

echo "============================================" | tee "$RESULTS_FILE"
echo "  PostgreSQL vs ClickHouse Benchmark" | tee -a "$RESULTS_FILE"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$RESULTS_FILE"
echo "============================================" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# === Start databases ===
echo "=== Starting databases ===" | tee -a "$RESULTS_FILE"
docker rm -f "$PG_CONTAINER" "$CH_CONTAINER" 2>/dev/null || true

docker run -d --name "$PG_CONTAINER" -p 15432:5432 \
  -e POSTGRES_DB=autoopt_demo -e POSTGRES_USER=autoopt -e POSTGRES_PASSWORD=autoopt \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:16 -c shared_preload_libraries=pg_stat_statements > /dev/null

docker run -d --name "$CH_CONTAINER" -p 18123:8123 \
  -e CLICKHOUSE_USER=autoopt -e CLICKHOUSE_PASSWORD=autoopt \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
  clickhouse/clickhouse-server:latest > /dev/null

echo "Waiting for databases..."
sleep 5
for i in $(seq 1 30); do docker exec "$PG_CONTAINER" pg_isready -U autoopt > /dev/null 2>&1 && break; sleep 1; done
for i in $(seq 1 10); do curl -sf "http://localhost:18123/?user=autoopt&password=autoopt" --data-binary "SELECT 1" > /dev/null 2>&1 && break; sleep 1; done

echo "PostgreSQL: $(echo 'SELECT version()' | pg -tA | head -1)" | tee -a "$RESULTS_FILE"
echo "ClickHouse: $(ch 'SELECT version()')" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# === Load data ===
echo "=== Loading data ===" | tee -a "$RESULTS_FILE"

echo "[setup] PostgreSQL: loading schema + 2M orders, 5M items + matview..."
cat "$SCRIPT_DIR/setup-postgres.sql" | pg 2>&1 | tail -1 | tee -a "$RESULTS_FILE"

echo "[setup] ClickHouse: loading schema + dimensions + dictionaries + flat table..."
# ClickHouse HTTP accepts one statement at a time — split on semicolons
sed 's/--.*$//' "$SCRIPT_DIR/setup-clickhouse.sql" | tr '\n' ' ' | sed 's/;/;\n/g' | while IFS= read -r stmt; do
  stmt=$(echo "$stmt" | sed 's/^ *//;s/ *$//')
  [ -z "$stmt" ] && continue
  ch "$stmt" 2>/dev/null || true
done

ch "SYSTEM RELOAD DICTIONARIES"
sleep 1
echo "ClickHouse facts: $(ch 'SELECT count() FROM order_facts') rows" | tee -a "$RESULTS_FILE"
echo "ClickHouse dicts: $(ch "SELECT name, element_count FROM system.dictionaries ORDER BY name FORMAT TabSeparated")" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# === Storage comparison ===
echo "=== Storage ===" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

echo "PostgreSQL:" | tee -a "$RESULTS_FILE"
echo "SELECT tablename, pg_size_pretty(pg_relation_size(tablename::regclass)) AS size FROM pg_tables WHERE schemaname='public' AND tablename IN ('orders','order_items','customers','products','categories') ORDER BY pg_relation_size(tablename::regclass) DESC;" | pg | tee -a "$RESULTS_FILE"

echo "" | tee -a "$RESULTS_FILE"
echo "ClickHouse:" | tee -a "$RESULTS_FILE"
ch "SELECT table, sum(rows) AS rows, formatReadableSize(sum(data_compressed_bytes)) AS compressed, formatReadableSize(sum(data_uncompressed_bytes)) AS raw FROM system.parts WHERE active AND database='default' AND table IN ('orders','order_items','order_facts','dim_customers','dim_products','dim_categories') GROUP BY table ORDER BY sum(data_compressed_bytes) DESC FORMAT PrettyCompact" | tee -a "$RESULTS_FILE"

echo "" | tee -a "$RESULTS_FILE"

# === The Query (same logic, 5 implementations) ===
echo "============================================" | tee -a "$RESULTS_FILE"
echo "  BENCHMARK: Weekly revenue by category × tier × region" | tee -a "$RESULTS_FILE"
echo "  5-table JOIN, date range 2024, GROUP BY 4 dimensions" | tee -a "$RESULTS_FILE"
echo "  $RUNS runs each" | tee -a "$RESULTS_FILE"
echo "============================================" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# --- 1. PostgreSQL raw ---
echo "--- 1. PostgreSQL raw (5-table JOIN, FK indexes) ---" | tee -a "$RESULTS_FILE"
for i in $(seq 1 $RUNS); do
  T=$(echo "EXPLAIN ANALYZE SELECT date_trunc('week', o.created_at) AS week, c.name AS category, cu.tier, cu.region, count(DISTINCT o.id) AS order_count, sum(oi.quantity) AS units, sum(oi.quantity * oi.unit_price * (1-oi.discount_pct/100)) AS revenue, sum(oi.quantity * (oi.unit_price * (1-oi.discount_pct/100) - p.cost)) AS profit FROM order_items oi JOIN orders o ON o.id=oi.order_id JOIN products p ON p.id=oi.product_id JOIN categories c ON c.id=p.category_id JOIN customers cu ON cu.id=o.customer_id WHERE o.created_at >= '2024-01-01' AND o.created_at < '2025-01-01' GROUP BY week, c.name, cu.tier, cu.region ORDER BY week, revenue DESC;" | pg 2>&1 | grep "Execution Time" | awk '{print $3}')
  echo "  run $i: ${T} ms" | tee -a "$RESULTS_FILE"
done
echo "" | tee -a "$RESULTS_FILE"

# --- 2. PostgreSQL matview ---
echo "--- 2. PostgreSQL + daily matview (1500 rows) ---" | tee -a "$RESULTS_FILE"
for i in $(seq 1 $RUNS); do
  T=$(echo "EXPLAIN ANALYZE SELECT date_trunc('week', day) AS week, category, tier, region, sum(order_count) AS order_count, sum(units_sold) AS units, sum(gross_revenue) AS revenue, sum(gross_profit) AS profit FROM mv_daily_sales WHERE day >= '2024-01-01' AND day < '2025-01-01' GROUP BY week, category, tier, region ORDER BY week, revenue DESC;" | pg 2>&1 | grep "Execution Time" | awk '{print $3}')
  echo "  run $i: ${T} ms" | tee -a "$RESULTS_FILE"
done
echo "" | tee -a "$RESULTS_FILE"

# --- 3. ClickHouse normalized (JOINs) ---
echo "--- 3. ClickHouse normalized (5-table JOIN) ---" | tee -a "$RESULTS_FILE"
for i in $(seq 1 $RUNS); do
  T=$(ch_time "SELECT toStartOfWeek(o.created_at) AS week, c.name AS cat, cu.tier, cu.region, uniqExact(o.id) AS order_count, sum(oi.quantity) AS units, sum(oi.quantity * oi.unit_price * (1-oi.discount_pct/100)) AS revenue, sum(oi.quantity * (oi.unit_price*(1-oi.discount_pct/100) - p.cost)) AS profit FROM order_items oi JOIN orders o ON o.id = oi.order_id JOIN dim_products p ON p.id = oi.product_id JOIN dim_categories c ON c.id = p.category_id JOIN dim_customers cu ON cu.id = o.customer_id WHERE o.created_at >= '2024-01-01' AND o.created_at < '2025-01-01' GROUP BY week, cat, tier, region ORDER BY week, revenue DESC FORMAT Null")
  MS=$(echo "$T * 1000" | bc | cut -d. -f1)
  echo "  run $i: ${MS} ms" | tee -a "$RESULTS_FILE"
done
echo "" | tee -a "$RESULTS_FILE"

# --- 4. ClickHouse dictGet ---
echo "--- 4. ClickHouse dictGet() (1 JOIN + in-memory lookups) ---" | tee -a "$RESULTS_FILE"
for i in $(seq 1 $RUNS); do
  T=$(ch_time "SELECT toStartOfWeek(o.created_at) AS week, dictGet('dict_categories','name',dictGet('dict_products','category_id',oi.product_id)) AS cat, dictGet('dict_customers','tier',o.customer_id) AS tier, dictGet('dict_customers','region',o.customer_id) AS region, uniqExact(o.id) AS order_count, sum(oi.quantity) AS units, sum(oi.quantity * oi.unit_price * (1-oi.discount_pct/100)) AS revenue, sum(oi.quantity * (oi.unit_price*(1-oi.discount_pct/100) - dictGet('dict_products','cost',oi.product_id))) AS profit FROM order_items oi JOIN orders o ON o.id = oi.order_id WHERE o.created_at >= '2024-01-01' AND o.created_at < '2025-01-01' GROUP BY week, cat, tier, region ORDER BY week, revenue DESC FORMAT Null")
  MS=$(echo "$T * 1000" | bc | cut -d. -f1)
  echo "  run $i: ${MS} ms" | tee -a "$RESULTS_FILE"
done
echo "" | tee -a "$RESULTS_FILE"

# --- 5. ClickHouse denormalized ---
echo "--- 5. ClickHouse denormalized (flat table, zero JOINs) ---" | tee -a "$RESULTS_FILE"
for i in $(seq 1 $RUNS); do
  T=$(ch_time "SELECT toStartOfWeek(created_at) AS week, category_name AS cat, customer_tier AS tier, customer_region AS region, uniqExact(order_id) AS order_count, sum(quantity) AS units, sum(line_revenue) AS revenue, sum(line_profit) AS profit FROM order_facts WHERE created_date >= '2024-01-01' AND created_date < '2025-01-01' GROUP BY week, cat, tier, region ORDER BY week, revenue DESC FORMAT Null")
  MS=$(echo "$T * 1000" | bc | cut -d. -f1)
  echo "  run $i: ${MS} ms" | tee -a "$RESULTS_FILE"
done
echo "" | tee -a "$RESULTS_FILE"

# --- Bonus: ClickHouse flat table with different time windows ---
echo "--- Bonus: ClickHouse flat table — flexible time windows ---" | tee -a "$RESULTS_FILE"
for grain in week month quarter year; do
  T=$(ch_time "SELECT toStartOfInterval(created_at, INTERVAL 1 $grain) AS period, category_name, customer_tier, customer_region, uniqExact(order_id), sum(line_revenue) AS rev FROM order_facts WHERE created_date >= '2024-01-01' AND created_date < '2025-01-01' GROUP BY period, category_name, customer_tier, customer_region ORDER BY period, rev DESC FORMAT Null")
  MS=$(echo "$T * 1000" | bc | cut -d. -f1)
  echo "  $grain: ${MS} ms" | tee -a "$RESULTS_FILE"
done
echo "" | tee -a "$RESULTS_FILE"

# --- Bonus: dictGet live value vs snapshot ---
echo "--- Bonus: dictGet (current value) vs snapshot (historical) ---" | tee -a "$RESULTS_FILE"
T_SNAP=$(ch_time "SELECT customer_tier, customer_region, sum(line_revenue) FROM order_facts GROUP BY customer_tier, customer_region ORDER BY sum(line_revenue) DESC FORMAT Null")
T_DICT=$(ch_time "SELECT dictGet('dict_customers','tier',customer_id) AS t, dictGet('dict_customers','region',customer_id) AS r, sum(line_revenue) FROM order_facts GROUP BY t, r ORDER BY sum(line_revenue) DESC FORMAT Null")
echo "  snapshot (all 5M rows): $(echo "$T_SNAP * 1000" | bc | cut -d. -f1) ms" | tee -a "$RESULTS_FILE"
echo "  dictGet  (all 5M rows): $(echo "$T_DICT * 1000" | bc | cut -d. -f1) ms" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# Summary
echo "============================================" | tee -a "$RESULTS_FILE"
echo "  SUMMARY" | tee -a "$RESULTS_FILE"
echo "============================================" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"
echo "Data: 100K customers, 10K products, 2M orders, 5M items" | tee -a "$RESULTS_FILE"
echo "Query: weekly revenue by category × tier × region (2024)" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"
echo "Results saved to: $RESULTS_FILE" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

echo "Containers still running. Cleanup: docker rm -f $PG_CONTAINER $CH_CONTAINER"
