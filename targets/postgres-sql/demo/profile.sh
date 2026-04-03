#!/bin/bash
# Profile PostgreSQL queries — the SQL equivalent of Phase 1 (Deep Profile)
# Usage: ./profile.sh [CONNECTION_STRING]
# Default: postgresql://localhost:5432/autoopt_demo
set -euo pipefail

CONNSTR="${1:-postgresql://localhost:5432/autoopt_demo}"
PSQL="psql $CONNSTR -X --pset=pager=off"

echo "=== PHASE 1: PostgreSQL Query Profiling ==="
echo ""

# 1. Table statistics — are tables being seq scanned?
echo "--- Table Scan Statistics (seq_scan vs idx_scan) ---"
echo "Tables with high seq_scan counts need indexes."
$PSQL -c "
SELECT
    schemaname || '.' || relname AS table_name,
    seq_scan,
    idx_scan,
    CASE WHEN seq_scan + idx_scan > 0
         THEN round(100.0 * seq_scan / (seq_scan + idx_scan), 1)
         ELSE 0
    END AS seq_scan_pct,
    n_live_tup AS row_count,
    pg_size_pretty(pg_relation_size(relid)) AS table_size
FROM pg_stat_user_tables
ORDER BY seq_scan DESC;
"

echo ""

# 2. Missing indexes — FK columns without indexes
echo "--- Foreign Key Columns Without Indexes ---"
echo "These cause seq scans on JOINs and WHERE filters."
$PSQL -c "
SELECT
    tc.table_name,
    kcu.column_name,
    ccu.table_name AS referenced_table,
    pg_size_pretty(pg_relation_size(tc.table_name::regclass)) AS table_size
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu
    ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND NOT EXISTS (
    SELECT 1 FROM pg_indexes pi
    WHERE pi.tablename = tc.table_name
      AND pi.indexdef LIKE '%' || kcu.column_name || '%'
  )
ORDER BY pg_relation_size(tc.table_name::regclass) DESC;
"

echo ""

# 3. Index usage — which indexes exist and are they used?
echo "--- Index Usage Statistics ---"
$PSQL -c "
SELECT
    schemaname || '.' || relname AS table_name,
    indexrelname AS index_name,
    idx_scan AS scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC;
"

echo ""

# 4. Cache hit ratio — are queries hitting shared_buffers or disk?
echo "--- Cache Hit Ratio ---"
$PSQL -c "
SELECT
    schemaname || '.' || relname AS table_name,
    heap_blks_read AS disk_reads,
    heap_blks_hit AS cache_hits,
    CASE WHEN heap_blks_hit + heap_blks_read > 0
         THEN round(100.0 * heap_blks_hit / (heap_blks_hit + heap_blks_read), 1)
         ELSE 100
    END AS hit_pct
FROM pg_statio_user_tables
ORDER BY heap_blks_read DESC;
"

echo ""

# 5. pg_stat_statements — top queries by total time (if available)
echo "--- Top Queries by Total Time (pg_stat_statements) ---"
$PSQL -c "
SELECT
    round(total_exec_time::numeric, 1) AS total_ms,
    calls,
    round((total_exec_time / calls)::numeric, 1) AS avg_ms,
    rows,
    round(shared_blks_hit::numeric / GREATEST(calls, 1), 0) AS avg_blks_hit,
    round(shared_blks_read::numeric / GREATEST(calls, 1), 0) AS avg_blks_read,
    left(query, 80) AS query_preview
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat%'
ORDER BY total_exec_time DESC
LIMIT 10;
" 2>/dev/null || echo "(pg_stat_statements not available — enable via shared_preload_libraries)"

echo ""
echo "=== PROFILING COMPLETE ==="
echo ""
echo "Next: Run EXPLAIN (ANALYZE, BUFFERS) on the slow queries identified above."
echo "See slow_queries.sql for the application queries to optimize."
