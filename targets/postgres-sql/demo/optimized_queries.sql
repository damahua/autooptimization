-- Optimized versions of the slow queries from slow_queries.sql
-- Changes: query rewrites + relies on indexes from optimize.sql

------------------------------------------------------------------------
-- QUERY 1 (optimized): Customer order history
-- Change: Replace correlated subqueries with a single LEFT JOIN + GROUP BY
-- Before: 2 correlated subqueries = 2 extra seq scans per row
-- After: 1 hash join on order_items (now indexed on order_id)
------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    o.id AS order_id,
    o.status,
    o.total_amount,
    o.created_at,
    count(oi.id) AS item_count,
    coalesce(sum(oi.quantity * oi.unit_price * (1 - oi.discount_pct/100)), 0) AS computed_total
FROM orders o
LEFT JOIN order_items oi ON oi.order_id = o.id
WHERE o.customer_id = 42
GROUP BY o.id, o.status, o.total_amount, o.created_at
ORDER BY o.created_at DESC
LIMIT 20;

------------------------------------------------------------------------
-- QUERY 2 (optimized): Sales dashboard revenue by category
-- Change: Filter orders FIRST using the composite index, then join
-- The CTE materializes only the relevant orders before the expensive join
------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
WITH filtered_orders AS (
    SELECT id, status
    FROM orders
    WHERE created_at >= '2024-06-01' AND created_at < '2024-07-01'
      AND status != 'cancelled'
)
SELECT
    c.name AS category,
    count(DISTINCT fo.id) AS order_count,
    sum(oi.quantity * oi.unit_price * (1 - oi.discount_pct/100)) AS revenue,
    avg(oi.quantity * oi.unit_price * (1 - oi.discount_pct/100)) AS avg_order_value
FROM filtered_orders fo
JOIN order_items oi ON oi.order_id = fo.id
JOIN products p ON p.id = oi.product_id
JOIN categories c ON c.id = p.category_id
GROUP BY c.name
ORDER BY revenue DESC;

------------------------------------------------------------------------
-- QUERY 3 (optimized): Product search
-- Change: Use the trigram index for text search, partial index for active+stock
-- The planner can now use idx_products_name_trgm for ILIKE and
-- idx_products_active_stock for the active+stock filter
------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    p.id, p.name, p.price, p.stock_quantity,
    c.name AS category
FROM products p
JOIN categories c ON c.id = p.category_id
WHERE p.is_active = true
  AND p.stock_quantity > 0
  AND (p.name ILIKE '%laptop%' OR c.name ILIKE '%laptop%')
ORDER BY p.price ASC
LIMIT 50;

------------------------------------------------------------------------
-- QUERY 4 (optimized): Shipping report
-- Change: Relies on partial composite index (status, created_at)
-- WHERE status IN ('pending', 'processing'). The partial index skips
-- delivered/cancelled orders entirely (~60% of the table).
-- Also: FK indexes on order_items.order_id and order_items.product_id
-- eliminate seq scans on the 5M-row table.
------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    o.id, o.customer_id, o.total_amount, o.created_at,
    cu.email, cu.name AS customer_name,
    count(oi.id) AS item_count,
    sum(p.weight_kg * oi.quantity) AS total_weight_kg
FROM orders o
JOIN customers cu ON cu.id = o.customer_id
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON p.id = oi.product_id
WHERE o.status = 'pending'
  AND o.created_at < now() - interval '3 days'
GROUP BY o.id, o.customer_id, o.total_amount, o.created_at, cu.email, cu.name
ORDER BY o.created_at ASC
LIMIT 100;

------------------------------------------------------------------------
-- QUERY 5 (optimized): VIP customer revenue
-- Change: CTE to filter VIP customers first (1K rows), then join orders.
-- With idx_orders_customer_id, the join uses an index scan per VIP customer
-- instead of scanning all 2M orders.
-- With idx_customers_tier partial index, VIP lookup is instant.
------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
WITH vip_customers AS (
    SELECT id, name, email, region
    FROM customers
    WHERE tier = 'vip'
)
SELECT
    vc.id, vc.name, vc.email, vc.region,
    count(o.id) AS total_orders,
    sum(o.total_amount) AS lifetime_value,
    max(o.created_at) AS last_order_at,
    avg(o.total_amount) AS avg_order_value
FROM vip_customers vc
JOIN orders o ON o.customer_id = vc.id
WHERE o.status != 'cancelled'
GROUP BY vc.id, vc.name, vc.email, vc.region
HAVING sum(o.total_amount) > 1000
ORDER BY lifetime_value DESC
LIMIT 50;
