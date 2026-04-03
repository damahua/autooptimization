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
