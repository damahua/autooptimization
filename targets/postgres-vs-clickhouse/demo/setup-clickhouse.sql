-- ClickHouse schema: 3 approaches (normalized, dictGet, denormalized)
-- Same data as PostgreSQL for apples-to-apples comparison

-- === DIMENSION TABLES ===

CREATE TABLE IF NOT EXISTS dim_categories (
    id UInt32, name String, parent_id Nullable(UInt32)
) ENGINE = MergeTree() ORDER BY id;

CREATE TABLE IF NOT EXISTS dim_customers (
    id UInt32, email String, name String,
    tier LowCardinality(String), region LowCardinality(String),
    updated_at DateTime
) ENGINE = ReplacingMergeTree(updated_at) ORDER BY id;

CREATE TABLE IF NOT EXISTS dim_products (
    id UInt32, name String, category_id UInt32,
    price Decimal(10,2), cost Decimal(10,2),
    weight_kg Decimal(6,2), is_active UInt8,
    updated_at DateTime
) ENGINE = ReplacingMergeTree(updated_at) ORDER BY id;

-- === LOAD DIMENSIONS ===

INSERT INTO dim_categories
SELECT number+1,
    arrayElement(['Electronics','Clothing','Home','Books','Sports','Phones','Laptops','Accessories','Men','Women','Kids','Kitchen','Furniture','Garden','Fiction','Non-Fiction','Technical','Outdoor','Indoor','Fitness'], number+1),
    CASE WHEN number<5 THEN NULL WHEN number<8 THEN 1 WHEN number<11 THEN 2 WHEN number<14 THEN 3 WHEN number<17 THEN 4 ELSE 5 END
FROM numbers(20);

INSERT INTO dim_customers
SELECT number+1, concat('user',toString(number+1),'@example.com'), concat('Customer ',toString(number+1)),
    multiIf(number%100=0,'vip', number%10=0,'premium', 'standard'),
    arrayElement(['us-east','us-west','eu-west','eu-central','ap-southeast'],1+(number%5)),
    toDateTime('2024-01-01')
FROM numbers(100000);

INSERT INTO dim_products
SELECT number+1, concat('Product ',toString(number+1)), 1+(number%20),
    toDecimal64(10+(number%500)+0.99,2), toDecimal64(5+(number%250)+0.50,2),
    toDecimal64(0.1+(number%50)*0.5,2), if(number%50!=0,1,0), toDateTime('2024-01-01')
FROM numbers(10000);

-- === DICTIONARIES (in-memory lookups) ===

CREATE DICTIONARY IF NOT EXISTS dict_customers (
    id UInt32, name String, email String, tier String, region String
) PRIMARY KEY id
SOURCE(CLICKHOUSE(TABLE 'dim_customers' USER 'autoopt' PASSWORD 'autoopt'))
LAYOUT(HASHED()) LIFETIME(MIN 60 MAX 120);

CREATE DICTIONARY IF NOT EXISTS dict_products (
    id UInt32, name String, category_id UInt32, price Decimal(10,2), cost Decimal(10,2), weight_kg Decimal(6,2)
) PRIMARY KEY id
SOURCE(CLICKHOUSE(TABLE 'dim_products' USER 'autoopt' PASSWORD 'autoopt'))
LAYOUT(HASHED()) LIFETIME(MIN 60 MAX 120);

CREATE DICTIONARY IF NOT EXISTS dict_categories (
    id UInt32, name String
) PRIMARY KEY id
SOURCE(CLICKHOUSE(TABLE 'dim_categories' USER 'autoopt' PASSWORD 'autoopt'))
LAYOUT(FLAT()) LIFETIME(3600);

SYSTEM RELOAD DICTIONARIES;

-- === NORMALIZED FACT TABLES (approach C: JOINs at query time) ===

CREATE TABLE IF NOT EXISTS orders (
    id UInt32, customer_id UInt32, status LowCardinality(String),
    total_amount Decimal(12,2), shipping_cost Decimal(8,2),
    created_at DateTime, updated_at DateTime,
    shipped_at Nullable(DateTime), delivered_at Nullable(DateTime)
) ENGINE = MergeTree() PARTITION BY toYYYYMM(created_at) ORDER BY (created_at, customer_id, id);

CREATE TABLE IF NOT EXISTS order_items (
    id UInt32, order_id UInt32, product_id UInt32,
    quantity UInt32, unit_price Decimal(10,2), discount_pct Decimal(5,2)
) ENGINE = MergeTree() ORDER BY (order_id, product_id, id);

-- === LOAD FACT DATA ===

INSERT INTO orders
SELECT number+1, 1+(number%100000),
    arrayElement(['pending','processing','shipped','delivered','cancelled'],1+(number%5)),
    toDecimal64(10+(number%1000)+0.99,2),
    if(number%3=0,toDecimal64(0,2),toDecimal64(5.99+(number%20),2)),
    toDateTime('2023-01-01')+toIntervalDay(number%730)+toIntervalMinute(number%1440),
    toDateTime('2023-01-01')+toIntervalDay(number%730+1),
    if(number%5>=2,toDateTime('2023-01-01')+toIntervalDay(number%730+2),NULL),
    if(number%5=3,toDateTime('2023-01-01')+toIntervalDay(number%730+5),NULL)
FROM numbers(2000000);

INSERT INTO order_items
SELECT number+1, 1+(number%2000000), 1+(number%10000), 1+(number%5),
    toDecimal64(10+(number%500)+0.99,2),
    if(number%10=0,toDecimal64(10,2),if(number%20=0,toDecimal64(20,2),toDecimal64(0,2)))
FROM numbers(5000000);

-- === DENORMALIZED FLAT TABLE (approach A: zero JOINs at query time) ===

CREATE TABLE IF NOT EXISTS order_facts (
    created_at DateTime,
    created_date Date DEFAULT toDate(created_at),
    order_id UInt32,
    order_status LowCardinality(String),
    order_total Decimal(12,2),
    item_id UInt32,
    quantity UInt32,
    unit_price Decimal(10,2),
    discount_pct Decimal(5,2),
    line_revenue Decimal(12,2),
    line_cost Decimal(12,2),
    line_profit Decimal(12,2),
    customer_id UInt32,
    customer_tier LowCardinality(String),
    customer_region LowCardinality(String),
    product_id UInt32,
    product_name String,
    product_cost Decimal(10,2),
    category_name LowCardinality(String)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_date, customer_region, category_name, order_id);

-- Populate flat table from normalized + dictionaries (the ONE-TIME JOIN)
INSERT INTO order_facts
SELECT
    o.created_at, toDate(o.created_at),
    o.id, o.status, o.total_amount,
    oi.id, oi.quantity, oi.unit_price, oi.discount_pct,
    oi.quantity * oi.unit_price * (1 - oi.discount_pct/100),
    oi.quantity * dictGet('dict_products', 'cost', oi.product_id),
    oi.quantity * (oi.unit_price * (1 - oi.discount_pct/100) - dictGet('dict_products', 'cost', oi.product_id)),
    o.customer_id,
    dictGet('dict_customers', 'tier', o.customer_id),
    dictGet('dict_customers', 'region', o.customer_id),
    oi.product_id,
    dictGet('dict_products', 'name', oi.product_id),
    dictGet('dict_products', 'cost', oi.product_id),
    dictGet('dict_categories', 'name', dictGet('dict_products', 'category_id', oi.product_id))
FROM order_items oi
JOIN orders o ON o.id = oi.order_id;

SELECT 'ClickHouse setup complete: ' ||
    toString(count()) || ' fact rows, ' ||
    toString((SELECT count() FROM orders)) || ' orders, ' ||
    toString((SELECT count() FROM order_items)) || ' items'
FROM order_facts;
