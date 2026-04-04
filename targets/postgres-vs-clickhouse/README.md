# PostgreSQL vs ClickHouse: Analytical Query Benchmark

Same data, same query, 5 approaches — from slowest to fastest.

## Quick Start

```bash
# Runs everything via Docker (~2 min total)
./demo/run.sh
```

## What Gets Tested

**Data:** 100K customers, 10K products, 20 categories, 2M orders, 5M order_items

**Query:** Weekly revenue by category × customer_tier × region, with date filter and 5-table JOIN

| # | Approach | JOINs at query | Dimension freshness |
|---|----------|---------------|-------------------|
| 1 | PostgreSQL raw | 4 JOINs | Real-time |
| 2 | PostgreSQL + matview | 0 (pre-aggregated) | Stale until refresh |
| 3 | ClickHouse normalized | 4 JOINs | Real-time |
| 4 | ClickHouse dictGet() | 1 JOIN + dict lookups | Dict refresh interval |
| 5 | ClickHouse denormalized | 0 JOINs | Snapshot at insert |

## Architecture

```
PostgreSQL (OLTP)                    ClickHouse (OLAP)
┌──────────────────┐                 ┌──────────────────────────────┐
│ 5 normalized     │  CDC / ETL      │ dim_* (ReplacingMergeTree)   │
│ tables           │ ──────────────→ │   ↓ auto-refresh             │
│                  │                 │ dict_* (in-memory Dictionary) │
│ + matview for    │                 │   ↓ dictGet() at insert      │
│   fixed dashboards│                │ order_facts (flat MergeTree) │
└──────────────────┘                 └──────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `target.md` | Methodology and metrics |
| `demo/setup-postgres.sql` | PostgreSQL schema + data + indexes + matview |
| `demo/setup-clickhouse.sql` | ClickHouse schema + dimensions + dictionaries + flat table |
| `demo/run.sh` | End-to-end benchmark runner |

## When to Use What

| Scenario | Best Approach |
|----------|--------------|
| Fixed dashboard, known dimensions | PostgreSQL matview |
| Ad-hoc analytics, unknown GROUP BY | ClickHouse dictGet() or flat table |
| Need current dimension values | ClickHouse dictGet() (auto-refreshed) |
| Need historical values | ClickHouse flat table snapshot columns |
| Maximum speed, any granularity | ClickHouse flat table |
| Adding new dimensions to existing data | ClickHouse dictGet() (no backfill) |
