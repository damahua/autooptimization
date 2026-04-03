-- Optimizations discovered by profiling (EXPLAIN ANALYZE + pg_stat_user_tables)
-- Apply these AFTER running baseline benchmarks, BEFORE running optimized benchmarks

------------------------------------------------------------------------
-- FIX 1: Add missing FK indexes
-- Profile evidence: seq_scan on orders (2M rows) for customer_id lookups
-- and seq_scan on order_items (5M rows) for order_id lookups
-- These are the #1 and #2 most impactful missing indexes
------------------------------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_customer_id
    ON orders (customer_id);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_order_items_order_id
    ON order_items (order_id);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_order_items_product_id
    ON order_items (product_id);

------------------------------------------------------------------------
-- FIX 2: Composite index for order status + date filtering
-- Profile evidence: Query 4 (shipping report) does seq scan on orders
-- filtering status='pending' AND created_at < threshold
-- A composite index lets PostgreSQL skip both the status and date filter
------------------------------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_status_created_at
    ON orders (status, created_at)
    WHERE status IN ('pending', 'processing');  -- partial index: only active statuses

------------------------------------------------------------------------
-- FIX 3: Composite index for orders date range + status
-- Profile evidence: Query 2 (sales dashboard) filters on created_at range + status
------------------------------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_created_at_status
    ON orders (created_at, status);

------------------------------------------------------------------------
-- FIX 4: Index for customer tier filtering
-- Profile evidence: Query 5 (VIP report) joins 2M orders but only needs
-- 1K VIP customers. Index on tier lets PostgreSQL start from the small set
------------------------------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_customers_tier
    ON customers (tier)
    WHERE tier IN ('vip', 'premium');  -- partial: only the tiers we filter on

------------------------------------------------------------------------
-- FIX 5: Trigram index for ILIKE text search
-- Profile evidence: Query 3 does ILIKE '%laptop%' on product names
-- B-tree can't help with leading wildcards; pg_trgm can
------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_name_trgm
    ON products USING gin (name gin_trgm_ops);

------------------------------------------------------------------------
-- FIX 6: Covering index for active products with stock
-- Profile evidence: Query 3 filters is_active=true AND stock_quantity > 0
-- A partial index skips inactive/out-of-stock products entirely
------------------------------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_active_stock
    ON products (price, id)
    INCLUDE (name, stock_quantity)
    WHERE is_active = true AND stock_quantity > 0;

------------------------------------------------------------------------
-- FIX 7: Daily-grain materialized view for flexible analytics
-- Profile evidence: Query 6 joins 5 tables producing 2.5M intermediate rows,
-- sorts spill to disk (73MB per worker), total execution 3.5s.
--
-- WHY daily grain (not weekly/monthly):
--   - Users change the dashboard time window: daily, weekly, monthly, quarterly
--   - A weekly matview breaks when someone picks "monthly" — you'd need N views
--   - Daily is the finest granularity dashboards use; sub-day goes to raw tables
--   - Daily collapses 2M orders × 2.5 items = 5M rows into ~1500 rows
--   - Any further GROUP BY (week, month, quarter) over 1500 rows is <2ms
--
-- Tradeoff: ~256KB storage (!), needs REFRESH after data changes.
-- On RDS: schedule via pg_cron (CREATE EXTENSION pg_cron) or Lambda trigger.
-- Use CONCURRENTLY to avoid locking reads during refresh.
------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_daily_sales AS
SELECT
    o.created_at::date AS day,
    c.name AS category,
    cu.tier,
    cu.region,
    o.status,
    count(DISTINCT o.id) AS order_count,
    count(DISTINCT o.customer_id) AS unique_customers,
    sum(oi.quantity) AS units_sold,
    sum(oi.quantity * oi.unit_price * (1 - oi.discount_pct/100)) AS gross_revenue,
    sum(oi.quantity * (oi.unit_price * (1 - oi.discount_pct/100) - p.cost)) AS gross_profit,
    sum(o.total_amount) AS total_order_amount,
    count(o.id) AS order_item_rows  -- for correct avg when rolling up
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
JOIN products p ON p.id = oi.product_id
JOIN categories c ON c.id = p.category_id
JOIN customers cu ON cu.id = o.customer_id
GROUP BY o.created_at::date, c.name, cu.tier, cu.region, o.status;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mv_daily_sales_day
    ON mv_daily_sales (day);

-- Re-analyze after adding indexes so the planner knows about them
ANALYZE customers;
ANALYZE products;
ANALYZE orders;
ANALYZE order_items;

-- Show what we created
SELECT
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname LIKE 'idx_%'
ORDER BY tablename, indexname;
