#!/bin/bash
set -uo pipefail

HOST="${SERVICE_HOST:-localhost}"
PORT="${SERVICE_PORT:-8123}"
BASE_URL="http://$HOST:$PORT"
PROFILE_DIR="${1:-.}"

echo "[profile] Collecting profiling data from ClickHouse system tables..."
echo "[profile] Target: $BASE_URL"
echo "[profile] Output: $PROFILE_DIR/"
echo ""

# Helper: run a ClickHouse query and print the result
run_query() {
    local result
    result=$(curl -s --max-time 30 "$BASE_URL" --data-binary "$1" 2>&1)
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "(query failed: curl exit $rc)"
        return 1
    fi
    if [ -z "$result" ]; then
        echo "(no data)"
        return 0
    fi
    echo "$result"
}

# Helper: run a ClickHouse query and save to file
run_query_to_file() {
    curl -s --max-time 30 "$BASE_URL" --data-binary "$1" > "$2" 2>/dev/null
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "(query to file failed: curl exit $rc)"
        return 1
    fi
    return 0
}

# 1. Query-level memory and timing
echo "[profile] === Per-Query Memory Usage ==="
run_query "
SELECT
    query,
    formatReadableSize(memory_usage) as peak_memory,
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes) as read_size,
    result_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query NOT LIKE '%system%'
  AND event_date = today()
ORDER BY memory_usage DESC
LIMIT 20
FORMAT PrettyCompact
"

# 2. CPU/Real trace flame graph data (stack traces)
echo ""
echo "[profile] === Wall-Clock Traces (top functions) ==="
run_query_to_file "
SELECT
    count() as samples,
    arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), trace), ';') as stack
FROM system.trace_log
WHERE trace_type = 'Real'
  AND event_date = today()
GROUP BY trace
ORDER BY samples DESC
LIMIT 30
FORMAT TabSeparated
SETTINGS allow_introspection_functions = 1
" "$PROFILE_DIR/cpu_traces.tsv"

if [ -s "$PROFILE_DIR/cpu_traces.tsv" ]; then
    echo "Wall-clock trace data saved. Top functions:"
    run_query "
    SELECT
        count() as samples,
        demangle(addressToSymbol(trace[1])) as top_function
    FROM system.trace_log
    WHERE trace_type = 'Real'
      AND event_date = today()
    GROUP BY top_function
    ORDER BY samples DESC
    LIMIT 20
    FORMAT PrettyCompact
    SETTINGS allow_introspection_functions = 1
    "
else
    echo "(no wall-clock traces captured)"
fi

# 3. Memory allocation traces (deeper call stack)
echo ""
echo "[profile] === Memory Allocation Traces (top callers at depth 5) ==="
run_query "
SELECT
    count() as samples,
    demangle(addressToSymbol(trace[5])) as caller_function,
    formatReadableSize(sum(abs(size))) as total_alloc
FROM system.trace_log
WHERE trace_type = 'Memory'
  AND event_date = today()
  AND length(trace) > 5
GROUP BY caller_function
ORDER BY sum(abs(size)) DESC
LIMIT 20
FORMAT PrettyCompact
SETTINGS allow_introspection_functions = 1
"

# 4. Memory allocation stack traces for flame graph
echo ""
echo "[profile] Saving memory trace data..."
run_query_to_file "
SELECT
    sum(abs(size)) as total_bytes,
    arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), trace), ';') as stack
FROM system.trace_log
WHERE trace_type = 'Memory'
  AND event_date = today()
GROUP BY trace
ORDER BY total_bytes DESC
LIMIT 50
FORMAT TabSeparated
SETTINGS allow_introspection_functions = 1
" "$PROFILE_DIR/memory_traces.tsv"

if [ -s "$PROFILE_DIR/memory_traces.tsv" ]; then
    echo "Memory trace data saved to memory_traces.tsv"
else
    echo "(no memory trace data)"
fi

# 5. Overall server memory breakdown
echo ""
echo "[profile] === Server Memory Breakdown ==="
run_query "
SELECT
    metric,
    formatReadableSize(value) as size
FROM system.metrics
WHERE metric LIKE '%Memory%' OR metric LIKE '%Cache%' OR metric LIKE '%Buffer%'
ORDER BY value DESC
FORMAT PrettyCompact
"

# 6. Asynchronous metrics (caches, pools)
echo ""
echo "[profile] === Cache and Buffer Metrics ==="
run_query "
SELECT
    metric,
    formatReadableSize(value) as size
FROM system.asynchronous_metrics
WHERE metric LIKE '%CacheSize%' OR metric LIKE '%CacheBytes%' OR metric LIKE '%MarkCache%'
ORDER BY value DESC
LIMIT 20
FORMAT PrettyCompact
"

# 7. Memory breakdown by allocator
echo ""
echo "[profile] === Memory Allocator Stats ==="
run_query "
SELECT
    metric,
    formatReadableSize(value) as size
FROM system.asynchronous_metrics
WHERE metric LIKE '%Allocated%' OR metric LIKE '%Mapped%' OR metric LIKE '%Resident%'
ORDER BY value DESC
LIMIT 20
FORMAT PrettyCompact
"

# 8. Server settings affecting memory
echo ""
echo "[profile] === Key Server Settings ==="
run_query "
SELECT name, value
FROM system.server_settings
WHERE name IN (
    'mark_cache_size', 'uncompressed_cache_size',
    'compiled_expression_cache_size',
    'max_server_memory_usage', 'max_server_memory_usage_to_ram_ratio',
    'max_thread_pool_size', 'max_thread_pool_free_size',
    'background_pool_size', 'background_schedule_pool_size',
    'background_common_pool_size', 'background_buffer_flush_schedule_pool_size',
    'background_fetches_pool_size', 'background_move_pool_size',
    'max_concurrent_queries'
)
ORDER BY name
FORMAT PrettyCompact
"

echo ""
echo "[profile] Profiling data saved to $PROFILE_DIR/"
echo "[profile] Files: cpu_traces.tsv, memory_traces.tsv"
