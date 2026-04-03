# Target: PostgreSQL SQL Optimization

## What this is

Unlike the ClickHouse/Chroma targets (which optimize database engine source code),
this target optimizes **SQL queries and schema** that applications run against
PostgreSQL. The database engine stays untouched — we optimize what runs ON it.

## Scope

- **Input**: SQL queries from application code (or slow query logs)
- **Changes**: Query rewrites, index additions, schema adjustments
- **Environment**: PostgreSQL on AWS RDS (or any PostgreSQL instance)
- **Metrics**: query latency (ms), planning time, execution time, rows scanned vs returned

## How it maps to the framework

| Framework Phase | SQL Optimization Equivalent |
|-----------------|---------------------------|
| Phase 0: Workload Discovery | Identify slow queries (pg_stat_statements, slow query log) |
| Phase 1: Deep Profile | EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON), pg_stat_user_tables, pg_stat_user_indexes |
| Phase 2: Identify Candidates | Find seq scans, bad join orders, missing indexes, suboptimal patterns |
| Phase 2.75: Verify Path | Confirm the query plan matches expectations before optimizing |
| Phase 3: Experiment Loop | Rewrite query / add index → re-run EXPLAIN ANALYZE → compare |

## Profiling tools

1. **EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)** — execution plan with actual timing and I/O
2. **pg_stat_statements** — aggregate query stats (calls, total_time, rows, shared_blks_hit/read)
3. **pg_stat_user_tables** — seq_scan vs idx_scan counts per table
4. **pg_stat_user_indexes** — index usage statistics
5. **pg_statio_user_tables** — heap blocks hit vs read (cache efficiency)
6. **auto_explain** — automatic EXPLAIN for queries exceeding threshold

## What counts as an optimization

**YES:**
- Query rewrite (restructure JOINs, replace subquery with CTE/JOIN, push filters down)
- Index addition (B-tree, partial, covering, expression indexes)
- Schema change (denormalization, materialized view, partitioning)

**NO:**
- PostgreSQL server config tuning (work_mem, shared_buffers, etc.)
- RDS instance class changes
- Application-level caching

Same principle as the framework: optimize HOW the query works, not WHAT numbers the server uses.

## A/B testing

For SQL, A/B testing is simpler than code changes:
1. Run original query N>=3 times, collect timing
2. Apply optimization (rewrite query, create index)
3. Run optimized query N>=3 times, collect timing
4. Compare distributions (same rules: must not overlap)
5. Also compare: rows scanned, buffers hit/read, planning time

**Always run `EXPLAIN (ANALYZE, BUFFERS)` before and after** — timing alone isn't enough.
The execution plan shows WHY the query is faster, not just that it is.
