#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
RESULTS_DIR="$FRAMEWORK_ROOT/results/$TARGET/$ENV"
PROFILE_DIR="$RESULTS_DIR/profiles"
FLAMEGRAPH_DIR="$FRAMEWORK_ROOT/tools/FlameGraph"

# Accept optional profile type: cpu, memory, or both (default: both)
PROFILE_TYPE="${PROFILE_TYPE:-both}"

echo "[profile] Profiling $TARGET (type: $PROFILE_TYPE)"

# 1. Check target has a profile.sh
if [ ! -f "$TARGET_DIR/profile.sh" ]; then
  echo "[profile] WARNING: No profile.sh found for target $TARGET. Skipping profiling."
  echo "[profile] To enable profiling, create targets/$TARGET/profile.sh"
  exit 0
fi

# 2. Read connection info
if [ -f "/tmp/autoopt-$TARGET-connection.env" ]; then
  source "/tmp/autoopt-$TARGET-connection.env"
fi
export SERVICE_HOST="${SERVICE_HOST:-localhost}"
export SERVICE_PORT="${SERVICE_PORT:-8080}"

# 3. Create profile output directory
mkdir -p "$PROFILE_DIR"

# 4. Run target-specific profiling — must output folded stack format
#    Target profile.sh contract:
#      Input:  SERVICE_HOST, SERVICE_PORT, PROFILE_TYPE (cpu|memory|both)
#      Output: writes .folded files to PROFILE_DIR
#              writes profiling_summary.txt to PROFILE_DIR
#      Exit:   0 = success
export PROFILE_TYPE PROFILE_DIR
echo "[profile] Running target profiling script..."
"$TARGET_DIR/profile.sh"
PROFILE_EXIT=$?
if [ $PROFILE_EXIT -ne 0 ]; then
  echo "[profile] WARNING: Target profiling failed (exit $PROFILE_EXIT)"
  exit $PROFILE_EXIT
fi

# 5. Generate flame graphs from folded stack files
if [ ! -d "$FLAMEGRAPH_DIR" ]; then
  echo "[profile] WARNING: FlameGraph tools not found at $FLAMEGRAPH_DIR"
  echo "[profile] Install: git clone https://github.com/brendangregg/FlameGraph.git $FLAMEGRAPH_DIR"
  echo "[profile] Skipping flame graph generation."
else
  for folded_file in "$PROFILE_DIR"/*.folded; do
    [ -f "$folded_file" ] || continue
    BASENAME=$(basename "$folded_file" .folded)

    # Determine flame graph options based on type
    TITLE="$TARGET"
    COLORS=""
    COUNTNAME="samples"
    case "$BASENAME" in
      *cpu*|*CPU*)
        TITLE="$TARGET CPU Profile"
        COUNTNAME="samples"
        ;;
      *memory*|*mem*|*alloc*)
        TITLE="$TARGET Memory Allocations"
        COLORS="--colors mem"
        COUNTNAME="bytes"
        ;;
      *)
        TITLE="$TARGET Profile ($BASENAME)"
        ;;
    esac

    SVG_FILE="$PROFILE_DIR/${BASENAME}_flamegraph.svg"
    echo "[profile] Generating flame graph: $SVG_FILE"
    perl "$FLAMEGRAPH_DIR/flamegraph.pl" \
      --title "$TITLE" \
      --countname "$COUNTNAME" \
      $COLORS \
      "$folded_file" > "$SVG_FILE" 2>/dev/null || \
      echo "[profile] WARNING: Failed to generate flame graph for $BASENAME"
  done
fi

# 6. Print summary
if [ -f "$PROFILE_DIR/profiling_summary.txt" ]; then
  echo ""
  echo "[profile] === Profiling Summary ==="
  cat "$PROFILE_DIR/profiling_summary.txt"
fi

echo ""
echo "[profile] Profiling complete. Results in $PROFILE_DIR/"
ls -la "$PROFILE_DIR/" 2>/dev/null | grep -v "^total"
