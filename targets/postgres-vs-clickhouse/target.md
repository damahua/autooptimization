# Target: PostgreSQL vs ClickHouse for Analytical Queries

## What this is

A head-to-head comparison of the same analytical workload (5-table JOIN with
time-based GROUP BY) across PostgreSQL and ClickHouse, showing:

1. **PostgreSQL raw** — normalized tables with FK indexes
2. **PostgreSQL + materialized view** — daily-grain pre-aggregation
3. **ClickHouse normalized** — same schema, columnar engine, JOINs at query time
4. **ClickHouse dictGet()** — dimensions in-memory, 1 JOIN reduced to hash lookups
5. **ClickHouse denormalized** — flat table, zero JOINs

## Metrics

- Query latency (ms) — N=5 runs per approach
- Storage size (compressed and raw)
- Flexibility (can you change GROUP BY dimensions without rebuilding?)

## Data

- 100K customers, 10K products, 20 categories
- 2M orders, 5M order_items
- Deterministic data generation (reproducible)

## Primary metric

Query latency on: weekly revenue by category × customer_tier × customer_region
with date range filter, 5-table JOIN.
