#!/bin/bash
# A/B benchmark for SQL queries — run before and after optimization
# Usage: ./benchmark.sh [CONNECTION_STRING] [QUERY_FILE] [LABEL] [RUNS]
# Example: ./benchmark.sh "postgresql://localhost/autoopt_demo" query1.sql baseline 5
set -euo pipefail

CONNSTR="${1:-postgresql://localhost:5432/autoopt_demo}"
QUERY_FILE="${2:?Usage: ./benchmark.sh <connstr> <query_file> <label> [runs]}"
LABEL="${3:?Usage: ./benchmark.sh <connstr> <query_file> <label> [runs]}"
RUNS="${4:-5}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../../../results/postgres-sql/local"
PSQL="psql $CONNSTR -X --pset=pager=off"

mkdir -p "$RESULTS_DIR"

echo "=== BENCHMARK: $LABEL ($RUNS runs) ==="
echo "[benchmark] Query: $QUERY_FILE"

# Strip EXPLAIN prefix if present — we want raw execution for timing
QUERY=$(cat "$QUERY_FILE" | sed 's/^EXPLAIN[^)]*) *//I')

# 1. Warmup (1 run, discard)
echo "[benchmark] Warmup..."
echo "$QUERY" | $PSQL > /dev/null 2>&1 || true

# 2. Capture execution plan (once)
echo "[benchmark] Execution plan:"
echo "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) $QUERY" | $PSQL

# 3. Measured runs
echo ""
echo "[benchmark] Timing ($RUNS runs)..."
TIMINGS=""
for run in $(seq 1 "$RUNS"); do
  # Use \timing for millisecond precision
  TIMING=$( (echo "\\timing on"; echo "$QUERY") | $PSQL 2>&1 | grep "^Time:" | awk '{print $2}')
  echo "  run $run: ${TIMING} ms"
  TIMINGS="$TIMINGS $TIMING"
done

# 4. Compute stats
echo ""
echo "[benchmark] Results for $LABEL:"
echo "$TIMINGS" | tr ' ' '\n' | grep -v '^$' | awk '
  { sum += $1; sumsq += $1*$1; vals[NR] = $1; n++ }
  END {
    if (n == 0) { print "No results"; exit 1 }
    mean = sum / n
    variance = (n > 1) ? (sumsq - sum*sum/n) / (n-1) : 0
    stddev = sqrt(variance)

    # Sort for median
    for (i = 1; i <= n; i++)
      for (j = i+1; j <= n; j++)
        if (vals[i] > vals[j]) { t = vals[i]; vals[i] = vals[j]; vals[j] = t }

    median = (n % 2 == 1) ? vals[int(n/2)+1] : (vals[n/2] + vals[n/2+1]) / 2
    printf "  mean:   %.1f ms\n", mean
    printf "  median: %.1f ms\n", median
    printf "  stddev: %.1f ms\n", stddev
    printf "  min:    %.1f ms\n", vals[1]
    printf "  max:    %.1f ms\n", vals[n]
    printf "  runs:   %d\n", n
  }
'

# 5. Save results
RESULTS_FILE="$RESULTS_DIR/${LABEL}-timing.txt"
echo "label=$LABEL" > "$RESULTS_FILE"
echo "query_file=$QUERY_FILE" >> "$RESULTS_FILE"
echo "runs=$RUNS" >> "$RESULTS_FILE"
echo "timings_ms=$TIMINGS" >> "$RESULTS_FILE"
echo "[benchmark] Results saved to $RESULTS_FILE"

echo "=== BENCHMARK COMPLETE ==="
