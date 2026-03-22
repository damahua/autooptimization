#!/bin/bash
# Compare two profile snapshots and generate differential flame graphs.
# Shows what got better (blue) and what got worse (red) between experiments.
#
# Usage: ./run.sh <env> compare.sh <target>
# Env vars:
#   BASELINE_PROFILE_DIR  — path to baseline profiles (e.g., results/<target>/<env>/profiles/baseline)
#   CURRENT_PROFILE_DIR   — path to current experiment profiles
#
set -euo pipefail
TARGET="$1"
RESULTS_DIR="$FRAMEWORK_ROOT/results/$TARGET/$ENV"
FLAMEGRAPH_DIR="$FRAMEWORK_ROOT/tools/FlameGraph"

BASELINE_PROFILE_DIR="${BASELINE_PROFILE_DIR:-$RESULTS_DIR/profiles/baseline}"
CURRENT_PROFILE_DIR="${CURRENT_PROFILE_DIR:-$RESULTS_DIR/profiles}"
DIFF_DIR="$RESULTS_DIR/profiles/diff"

echo "[compare] Comparing profiles: baseline vs current"
echo "[compare] Baseline: $BASELINE_PROFILE_DIR"
echo "[compare] Current:  $CURRENT_PROFILE_DIR"

if [ ! -d "$FLAMEGRAPH_DIR" ]; then
  echo "[compare] ERROR: FlameGraph tools not found at $FLAMEGRAPH_DIR"
  exit 1
fi

mkdir -p "$DIFF_DIR"

# Generate differential flame graphs for each matching .folded pair
for current_folded in "$CURRENT_PROFILE_DIR"/*.folded; do
  [ -f "$current_folded" ] || continue
  BASENAME=$(basename "$current_folded" .folded)
  baseline_folded="$BASELINE_PROFILE_DIR/${BASENAME}.folded"

  if [ ! -f "$baseline_folded" ]; then
    echo "[compare] WARNING: No baseline for $BASENAME, skipping diff"
    continue
  fi

  echo "[compare] Generating diff flame graph for $BASENAME..."

  # difffolded.pl generates differential data
  # Red = regression (more samples/bytes), Blue = improvement (fewer)
  perl "$FLAMEGRAPH_DIR/difffolded.pl" \
    "$baseline_folded" "$current_folded" \
    > "$DIFF_DIR/${BASENAME}_diff.folded" 2>/dev/null

  TITLE="$TARGET $BASENAME DIFF (red=worse, blue=better)"
  perl "$FLAMEGRAPH_DIR/flamegraph.pl" \
    --title "$TITLE" \
    --negate \
    "$DIFF_DIR/${BASENAME}_diff.folded" \
    > "$DIFF_DIR/${BASENAME}_diff_flamegraph.svg" 2>/dev/null || \
    echo "[compare] WARNING: Failed to generate diff flame graph for $BASENAME"
done

# Generate numeric comparison
{
  echo "=== Profile Comparison: Baseline vs Current ==="
  echo ""

  for type in cpu memory; do
    baseline_folded="$BASELINE_PROFILE_DIR/${type}.folded"
    current_folded="$CURRENT_PROFILE_DIR/${type}.folded"

    if [ -f "$baseline_folded" ] && [ -f "$current_folded" ]; then
      BASELINE_TOTAL=$(awk '{sum += $NF} END {print sum}' "$baseline_folded" 2>/dev/null || echo 0)
      CURRENT_TOTAL=$(awk '{sum += $NF} END {print sum}' "$current_folded" 2>/dev/null || echo 0)

      echo "--- $type ---"
      echo "Baseline total: $BASELINE_TOTAL"
      echo "Current total:  $CURRENT_TOTAL"
      if [ "$BASELINE_TOTAL" -gt 0 ] 2>/dev/null; then
        DELTA=$(echo "scale=1; ($CURRENT_TOTAL - $BASELINE_TOTAL) * 100 / $BASELINE_TOTAL" | bc 2>/dev/null || echo "N/A")
        echo "Delta: ${DELTA}%"
      fi
      echo ""

      # Show top functions that changed most
      echo "Top changes (functions with biggest delta):"
      paste <(
        awk -F'\t' '{split($1,a,";"); print a[length(a)], $NF}' "$baseline_folded" | sort -k1,1
      ) <(
        awk -F'\t' '{split($1,a,";"); print a[length(a)], $NF}' "$current_folded" | sort -k1,1
      ) 2>/dev/null | head -20 || echo "(comparison failed)"
      echo ""
    fi
  done
} > "$DIFF_DIR/comparison_summary.txt"

cat "$DIFF_DIR/comparison_summary.txt"

echo ""
echo "[compare] Diff results in $DIFF_DIR/"
ls -la "$DIFF_DIR/" 2>/dev/null | grep -v "^total"
