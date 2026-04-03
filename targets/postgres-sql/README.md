# PostgreSQL SQL Optimization Target

Optimize **application SQL queries**, not the database engine. The database stays
untouched — we optimize what runs ON it (queries, indexes, schema).

## The Problem

Applications hit PostgreSQL with queries that worked fine at 10K rows but fall
apart at 2M+ rows. Common patterns:
- Missing FK indexes → seq scans on JOINs
- Correlated subqueries → N+1 execution
- No composite indexes → full table scans for multi-column filters
- ILIKE with leading wildcards → can't use B-tree indexes
- Wrong join order → scanning the large table first

## How It Works

Same framework loop, different "code changes":

```
Profile (EXPLAIN ANALYZE, pg_stat_user_tables)
    → Identify (seq scans, missing indexes, bad plans)
    → Implement (add indexes, rewrite queries)
    → Benchmark (N>=3 runs, compare timing distributions)
    → Keep/Discard
```

## Demo

```bash
# Run the full demo (starts PostgreSQL via Docker, ~2 min)
./demo/run.sh

# Or point at an existing PostgreSQL:
./demo/run.sh "postgresql://user:pass@host:5432/dbname"
```

The demo:
1. Creates an e-commerce schema (100K customers, 10K products, 2M orders, 5M items)
2. Profiles — finds missing FK indexes, seq scans, cache misses
3. Benchmarks 5 slow queries (baseline)
4. Applies optimizations (6 indexes + query rewrites)
5. Benchmarks the same queries (optimized)
6. Shows before/after comparison

## Files

| File | Purpose |
|------|---------|
| `target.md` | Methodology: how framework phases map to SQL optimization |
| `demo/setup.sql` | E-commerce schema + deterministic data generation |
| `demo/slow_queries.sql` | 5 application queries with intentional performance problems |
| `demo/profile.sh` | Phase 1: table stats, missing indexes, cache ratios, pg_stat_statements |
| `demo/optimize.sql` | Optimizations: FK indexes, composite indexes, trigram index, partial indexes |
| `demo/optimized_queries.sql` | Rewritten queries that leverage the new indexes |
| `demo/benchmark.sh` | A/B benchmark tool for individual queries |
| `demo/run.sh` | End-to-end demo runner |

## For AWS RDS

The same approach works on RDS with these notes:
- `pg_stat_statements` is available via RDS parameter groups (set `shared_preload_libraries`)
- `CREATE INDEX CONCURRENTLY` works on RDS (non-blocking)
- `pg_trgm` extension is supported on RDS
- Use Performance Insights for top SQL identification (replaces manual pg_stat_statements)
- Connection string: `postgresql://user:pass@your-rds-endpoint:5432/dbname`

No RDS config changes needed — all optimizations are query-level and schema-level.
