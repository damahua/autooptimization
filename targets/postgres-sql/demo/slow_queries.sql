-- Application SQL queries that need optimization
-- These simulate real queries from a dashboard, API endpoints, and reports
-- Each has a specific performance problem the agent should discover via EXPLAIN ANALYZE

------------------------------------------------------------------------
-- QUERY 1: Customer order history (API endpoint: GET /customers/:id/orders)
-- Problem: seq scan on orders.customer_id (no FK index), correlated subquery
------------------------------------------------------------------------
-- "For a given customer, get their recent orders with item count and total"
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    o.id AS order_id,
    o.status,
    o.total_amount,
    o.created_at,
    (SELECT count(*) FROM order_items oi WHERE oi.order_id = o.id) AS item_count,
    (SELECT sum(oi.quantity * oi.unit_price * (1 - oi.discount_pct/100))
     FROM order_items oi WHERE oi.order_id = o.id) AS computed_total
FROM orders o
WHERE o.customer_id = 42
ORDER BY o.created_at DESC
LIMIT 20;

------------------------------------------------------------------------
-- QUERY 2: Sales dashboard — revenue by category (daily cron report)
-- Problem: joins without indexes on FK columns, no filter pushdown
------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    c.name AS category,
    count(DISTINCT o.id) AS order_count,
    sum(oi.quantity * oi.unit_price * (1 - oi.discount_pct/100)) AS revenue,
    avg(oi.quantity * oi.unit_price * (1 - oi.discount_pct/100)) AS avg_order_value
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
JOIN products p ON p.id = oi.product_id
JOIN categories c ON c.id = p.category_id
WHERE o.created_at >= '2024-06-01' AND o.created_at < '2024-07-01'
  AND o.status != 'cancelled'
GROUP BY c.name
ORDER BY revenue DESC;

------------------------------------------------------------------------
-- QUERY 3: Product search with stock check (API: GET /products?search=...)
-- Problem: LIKE without trigram index, filtering active+stock in seq scan
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
-- QUERY 4: Shipping report — unshipped orders older than 3 days
-- Problem: seq scan on orders for status + date filter, no composite index
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
-- QUERY 5: VIP customer revenue (monthly exec report)
-- Problem: scanning all orders to join with a small customer subset
------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    cu.id, cu.name, cu.email, cu.region,
    count(o.id) AS total_orders,
    sum(o.total_amount) AS lifetime_value,
    max(o.created_at) AS last_order_at,
    avg(o.total_amount) AS avg_order_value
FROM customers cu
JOIN orders o ON o.customer_id = cu.id
WHERE cu.tier = 'vip'
  AND o.status != 'cancelled'
GROUP BY cu.id, cu.name, cu.email, cu.region
HAVING sum(o.total_amount) > 1000
ORDER BY lifetime_value DESC
LIMIT 50;

------------------------------------------------------------------------
-- QUERY 6: Weekly analytics dashboard (BI tool / exec report)
-- Problem: 5-table join producing 2.5M intermediate rows, GROUP BY on
-- 4 dimensions with date_trunc, sorts spilling to disk (73MB per worker).
-- This is the "super complex join with time GROUP BY" pattern.
-- Fix: materialized view that pre-joins and pre-aggregates at order level
------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    date_trunc('week', o.created_at) AS week,
    c.name AS category,
    cu.tier,
    cu.region,
    count(DISTINCT o.id) AS order_count,
    count(DISTINCT o.customer_id) AS unique_customers,
    sum(oi.quantity) AS units_sold,
    sum(oi.quantity * oi.unit_price * (1 - oi.discount_pct/100)) AS gross_revenue,
    sum(oi.quantity * (oi.unit_price * (1 - oi.discount_pct/100) - p.cost)) AS gross_profit,
    avg(o.total_amount) AS avg_order_value,
    sum(CASE WHEN o.status = 'cancelled' THEN 1 ELSE 0 END)::float
        / NULLIF(count(DISTINCT o.id), 0) AS cancel_rate
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
JOIN products p ON p.id = oi.product_id
JOIN categories c ON c.id = p.category_id
JOIN customers cu ON cu.id = o.customer_id
WHERE o.created_at >= '2024-01-01' AND o.created_at < '2025-01-01'
GROUP BY
    date_trunc('week', o.created_at),
    c.name,
    cu.tier,
    cu.region
ORDER BY week, gross_revenue DESC;
