#!/bin/bash
# EXAMPLE: Profile Analysis & A/B Comparison
# PURPOSE: Parse raw profiling data (smaps, perf, target-specific) into
#   actionable summaries. Optionally compare two profiles (baseline vs experiment).
# KEY PATTERNS:
#   - smaps aggregation: categorize RSS by type (heap, anon_mmap, file-backed)
#   - Top memory regions sorted by RSS to find dominant allocations
#   - CPU function ranking from perf script output
#   - A/B delta computation for key metrics between two profiles
# NOTE: This is a teaching example. The AI agent adapts these patterns for
#   each target rather than running this script via the dispatcher.
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
RESULTS_DIR="$FRAMEWORK_ROOT/results/$TARGET/$ENV"
SCRIPT_NAME="analyze"
source "$FRAMEWORK_ROOT/examples/lifecycle/log.sh"

PROFILE_LABEL="${PROFILE_LABEL:-unlabeled}"
PROFILE_COMPARE_TO="${PROFILE_COMPARE_TO:-}"
PROFILES_DIR="$RESULTS_DIR/profiles"
TOP_N="${ANALYZE_TOP_N:-20}"

log_separator "ANALYZE: $TARGET (label: $PROFILE_LABEL)"

ANALYSIS_FILE="$PROFILES_DIR/${PROFILE_LABEL}-analysis.txt"
SMAPS_FILE="$PROFILES_DIR/${PROFILE_LABEL}-smaps.txt"
STATUS_FILE="$PROFILES_DIR/${PROFILE_LABEL}-status.txt"
PERF_FILE="$PROFILES_DIR/${PROFILE_LABEL}-perf.txt"
TARGET_PROFILE="$PROFILES_DIR/${PROFILE_LABEL}-target-profile.txt"

# === Parse /proc/1/status ===
log_step "BEFORE" "Analyzing profile: $PROFILE_LABEL"

{
echo "=== MEMORY PROFILE: $PROFILE_LABEL ==="

if [ -f "$STATUS_FILE" ]; then
  VM_HWM_KB=$(grep VmHWM "$STATUS_FILE" | awk '{print $2}' || echo 0)
  VM_RSS_KB=$(grep VmRSS "$STATUS_FILE" | awk '{print $2}' || echo 0)
  VM_SIZE_KB=$(grep VmSize "$STATUS_FILE" | awk '{print $2}' || echo 0)
  VM_DATA_KB=$(grep VmData "$STATUS_FILE" | awk '{print $2}' || echo 0)
  VM_STK_KB=$(grep VmStk "$STATUS_FILE" | awk '{print $2}' || echo 0)
  VM_LIB_KB=$(grep VmLib "$STATUS_FILE" | awk '{print $2}' || echo 0)

  echo "peak_rss_mb=$(echo "scale=1; ${VM_HWM_KB:-0} / 1024" | bc)"
  echo "current_rss_mb=$(echo "scale=1; ${VM_RSS_KB:-0} / 1024" | bc)"
  echo "virtual_mb=$(echo "scale=1; ${VM_SIZE_KB:-0} / 1024" | bc)"
  echo "data_mb=$(echo "scale=1; ${VM_DATA_KB:-0} / 1024" | bc)"
  echo "stack_mb=$(echo "scale=1; ${VM_STK_KB:-0} / 1024" | bc)"
  echo "lib_mb=$(echo "scale=1; ${VM_LIB_KB:-0} / 1024" | bc)"
fi

# === Parse smaps — aggregate RSS by mapping type ===
if [ -f "$SMAPS_FILE" ] && [ -s "$SMAPS_FILE" ]; then
  echo ""
  echo "--- Memory Breakdown (from smaps) ---"

  # Aggregate RSS by mapping type: [heap], [stack], anonymous, file-backed
  awk '
  /^[0-9a-f]/ {
    # Parse the mapping line: addr perms offset dev inode pathname
    mapping = ""
    if (NF >= 6) mapping = $NF
    if (mapping == "") mapping = "[anon]"
  }
  /^Rss:/ {
    rss_kb = $2
    if (mapping == "[heap]") heap += rss_kb
    else if (mapping == "[stack]") stack += rss_kb
    else if (mapping ~ /\.so/ || mapping ~ /^\//) file_backed += rss_kb
    else anon += rss_kb
    total += rss_kb
  }
  END {
    printf "total_rss_mb=%.1f\n", total/1024
    printf "heap_mb=%.1f\n", heap/1024
    printf "anon_mmap_mb=%.1f\n", anon/1024
    printf "file_backed_mb=%.1f\n", file_backed/1024
    printf "stack_mb=%.1f\n", stack/1024
  }
  ' "$SMAPS_FILE"

  echo ""
  echo "--- Top Memory Regions (by RSS, top $TOP_N) ---"
  echo "rank  rss_mb   type        mapping"

  # Extract individual regions with their RSS
  awk '
  /^[0-9a-f]/ {
    mapping = ""
    if (NF >= 6) mapping = $NF
    if (mapping == "") mapping = "[anon]"
    addr = $1
  }
  /^Rss:/ {
    rss_kb = $2
    if (rss_kb > 0) {
      type = "unknown"
      if (mapping == "[heap]") type = "heap"
      else if (mapping == "[stack]") type = "stack"
      else if (mapping ~ /\.so/ || mapping ~ /^\//) type = "file"
      else type = "anon_mmap"
      printf "%.1f\t%s\t%s\n", rss_kb/1024, type, mapping
    }
  }
  ' "$SMAPS_FILE" | sort -rn | head -"$TOP_N" | awk -F'\t' '{printf "%-5d %-8s %-11s %s\n", NR, $1, $2, $3}'
fi

# === Parse CPU profile (perf script output) ===
if [ -f "$PERF_FILE" ] && [ -s "$PERF_FILE" ]; then
  echo ""
  echo "=== CPU PROFILE: $PROFILE_LABEL ==="

  TOTAL_SAMPLES=$(grep -c "^$" "$PERF_FILE" 2>/dev/null || echo 0)
  echo "total_samples=$TOTAL_SAMPLES"

  echo ""
  echo "--- Top Functions (by samples, top $TOP_N) ---"
  echo "rank  samples  pct     function"

  # Extract function names from perf script output (lines with function names after addresses)
  # Use sed instead of grep -P for macOS compatibility
  sed -n 's/.*\(\([^ ]*\)+0x[0-9a-f]*\).*/\1/p' "$PERF_FILE" 2>/dev/null | \
    sed 's/+0x[0-9a-f]*$//' | \
    sort | uniq -c | sort -rn | head -"$TOP_N" | \
    awk -v total="$TOTAL_SAMPLES" '{
      pct = (total > 0) ? $1*100/total : 0
      printf "%-5d %-8d %-7.1f%% %s\n", NR, $1, pct, $2
    }'
else
  echo ""
  echo "=== CPU PROFILE: not available ==="
fi

# === Target-specific profile ===
if [ -f "$TARGET_PROFILE" ] && [ -s "$TARGET_PROFILE" ]; then
  echo ""
  echo "=== TARGET-SPECIFIC PROFILE ==="
  cat "$TARGET_PROFILE"
fi

} > "$ANALYSIS_FILE"

log_status "Analysis written to $ANALYSIS_FILE"

# === Comparison mode ===
if [ -n "$PROFILE_COMPARE_TO" ]; then
  COMPARE_ANALYSIS="$PROFILES_DIR/${PROFILE_COMPARE_TO}-analysis.txt"
  DIFF_FILE="$PROFILES_DIR/${PROFILE_LABEL}-vs-${PROFILE_COMPARE_TO}-diff.txt"

  if [ -f "$COMPARE_ANALYSIS" ]; then
    log_status "Comparing $PROFILE_LABEL vs $PROFILE_COMPARE_TO..."

    {
    echo "=== PROFILE DIFF: $PROFILE_LABEL vs $PROFILE_COMPARE_TO ==="
    echo ""
    echo "--- Memory Summary ---"
    printf "%-20s %-12s %-12s %-12s %-10s\n" "metric" "$PROFILE_COMPARE_TO" "$PROFILE_LABEL" "delta" "delta_pct"

    # Extract key metrics from both analysis files and compute deltas
    for metric in peak_rss_mb current_rss_mb heap_mb anon_mmap_mb total_rss_mb; do
      BASE_VAL=$(grep "^${metric}=" "$COMPARE_ANALYSIS" 2>/dev/null | head -1 | cut -d= -f2 || echo 0)
      EXP_VAL=$(grep "^${metric}=" "$ANALYSIS_FILE" 2>/dev/null | head -1 | cut -d= -f2 || echo 0)
      if [ -n "$BASE_VAL" ] && [ -n "$EXP_VAL" ] && [ "$BASE_VAL" != "0" ]; then
        DELTA=$(echo "scale=1; $EXP_VAL - $BASE_VAL" | bc 2>/dev/null || echo "N/A")
        DELTA_PCT=$(echo "scale=1; ($EXP_VAL - $BASE_VAL) * 100 / $BASE_VAL" | bc 2>/dev/null || echo "N/A")
        printf "%-20s %-12s %-12s %-12s %-10s\n" "$metric" "$BASE_VAL" "$EXP_VAL" "$DELTA" "${DELTA_PCT}%"
      fi
    done

    # Include target-specific comparison if both have target profiles
    BASE_TARGET="$PROFILES_DIR/${PROFILE_COMPARE_TO}-target-profile.txt"
    EXP_TARGET="$PROFILES_DIR/${PROFILE_LABEL}-target-profile.txt"
    if [ -f "$BASE_TARGET" ] && [ -f "$EXP_TARGET" ]; then
      echo ""
      echo "--- Target-Specific Comparison ---"
      echo "(baseline)"
      head -20 "$BASE_TARGET"
      echo ""
      echo "(experiment)"
      head -20 "$EXP_TARGET"
    fi

    } > "$DIFF_FILE"

    log_status "Diff written to $DIFF_FILE"
  else
    log_warn "No analysis file for $PROFILE_COMPARE_TO — skipping comparison"
  fi
fi

# Print analysis to stdout for the agent
cat "$ANALYSIS_FILE"
if [ -n "$PROFILE_COMPARE_TO" ] && [ -f "${DIFF_FILE:-/dev/null}" ]; then
  echo ""
  cat "$DIFF_FILE"
fi

log_step "AFTER" "Analysis complete for $PROFILE_LABEL"
