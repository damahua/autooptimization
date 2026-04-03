-- E-commerce schema with realistic data for SQL optimization demo
-- Simulates an application hitting PostgreSQL on AWS RDS
-- ~2M orders, ~100K customers, ~10K products, ~5M order_items

-- Clean slate
DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS customers CASCADE;
DROP TABLE IF EXISTS categories CASCADE;

-- Categories
CREATE TABLE categories (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    parent_id INTEGER REFERENCES categories(id)
);

INSERT INTO categories (name, parent_id) VALUES
    ('Electronics', NULL), ('Clothing', NULL), ('Home', NULL), ('Books', NULL), ('Sports', NULL),
    ('Phones', 1), ('Laptops', 1), ('Accessories', 1),
    ('Men', 2), ('Women', 2), ('Kids', 2),
    ('Kitchen', 3), ('Furniture', 3), ('Garden', 3),
    ('Fiction', 4), ('Non-Fiction', 4), ('Technical', 4),
    ('Outdoor', 5), ('Indoor', 5), ('Fitness', 5);

-- Customers (~100K)
CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) NOT NULL,
    name VARCHAR(200) NOT NULL,
    tier VARCHAR(20) NOT NULL DEFAULT 'standard',  -- standard, premium, vip
    region VARCHAR(50) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    last_login_at TIMESTAMP
);

INSERT INTO customers (email, name, tier, region, created_at, last_login_at)
SELECT
    'user' || n || '@example.com',
    'Customer ' || n,
    CASE
        WHEN n % 100 = 0 THEN 'vip'
        WHEN n % 10 = 0 THEN 'premium'
        ELSE 'standard'
    END,
    (ARRAY['us-east', 'us-west', 'eu-west', 'eu-central', 'ap-southeast'])[1 + (n % 5)],
    '2022-01-01'::timestamp + (n % 730 || ' days')::interval,
    '2024-01-01'::timestamp + (n % 365 || ' days')::interval
FROM generate_series(1, 100000) AS n;

-- Products (~10K)
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(300) NOT NULL,
    category_id INTEGER NOT NULL REFERENCES categories(id),
    price NUMERIC(10,2) NOT NULL,
    cost NUMERIC(10,2) NOT NULL,
    stock_quantity INTEGER NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    weight_kg NUMERIC(6,2)
);

INSERT INTO products (name, category_id, price, cost, stock_quantity, is_active, created_at, weight_kg)
SELECT
    'Product ' || n,
    1 + (n % 20),
    10 + (n % 500)::numeric + 0.99,
    5 + (n % 250)::numeric + 0.50,
    (n * 17) % 1000,
    n % 50 != 0,  -- 2% inactive
    '2022-06-01'::timestamp + (n % 365 || ' days')::interval,
    0.1 + (n % 50)::numeric * 0.5
FROM generate_series(1, 10000) AS n;

-- Orders (~2M)
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    status VARCHAR(20) NOT NULL,  -- pending, processing, shipped, delivered, cancelled
    total_amount NUMERIC(12,2) NOT NULL,
    shipping_cost NUMERIC(8,2) NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL,
    shipped_at TIMESTAMP,
    delivered_at TIMESTAMP,
    notes TEXT
);

INSERT INTO orders (customer_id, status, total_amount, shipping_cost, created_at, updated_at, shipped_at, delivered_at)
SELECT
    1 + (n % 100000),
    (ARRAY['pending', 'processing', 'shipped', 'delivered', 'cancelled'])[1 + (n % 5)],
    10 + (n % 1000)::numeric + 0.99,
    CASE WHEN n % 3 = 0 THEN 0 ELSE 5.99 + (n % 20)::numeric END,
    '2023-01-01'::timestamp + ((n % 730) || ' days')::interval + ((n % 1440) || ' minutes')::interval,
    '2023-01-01'::timestamp + ((n % 730 + 1) || ' days')::interval,
    CASE WHEN n % 5 >= 2 THEN '2023-01-01'::timestamp + ((n % 730 + 2) || ' days')::interval END,
    CASE WHEN n % 5 = 3 THEN '2023-01-01'::timestamp + ((n % 730 + 5) || ' days')::interval END
FROM generate_series(1, 2000000) AS n;

-- Order items (~5M, avg 2.5 items per order)
CREATE TABLE order_items (
    id SERIAL PRIMARY KEY,
    order_id INTEGER NOT NULL REFERENCES orders(id),
    product_id INTEGER NOT NULL REFERENCES products(id),
    quantity INTEGER NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL,
    discount_pct NUMERIC(5,2) NOT NULL DEFAULT 0
);

INSERT INTO order_items (order_id, product_id, quantity, unit_price, discount_pct)
SELECT
    1 + (n % 2000000),
    1 + (n % 10000),
    1 + (n % 5),
    10 + (n % 500)::numeric + 0.99,
    CASE WHEN n % 10 = 0 THEN 10.00 WHEN n % 20 = 0 THEN 20.00 ELSE 0 END
FROM generate_series(1, 5000000) AS n;

-- Only add PRIMARY KEY indexes (FK indexes intentionally omitted — this is realistic!)
-- Many production databases forget to index FK columns
-- The optimization agent should discover this via profiling

-- Add pg_stat_statements if available
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Warm the stats
ANALYZE customers;
ANALYZE products;
ANALYZE orders;
ANALYZE order_items;
ANALYZE categories;

SELECT 'Setup complete: ' ||
    (SELECT count(*) FROM customers) || ' customers, ' ||
    (SELECT count(*) FROM products) || ' products, ' ||
    (SELECT count(*) FROM orders) || ' orders, ' ||
    (SELECT count(*) FROM order_items) || ' order_items';
