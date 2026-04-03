#!/bin/bash
# Run the full POC demo: baseline + 3 experiments
set -euo pipefail
cd "$(dirname "$0")/../.."

# Speed overrides for demo
export WARMUP_SECONDS=5
export WORKLOAD_RUNS=1
export RESOURCE_LIMITS_MEMORY=512Mi
export RESOURCE_REQUESTS_MEMORY=256Mi
export RESOURCE_LIMITS_CPU=1
export RESOURCE_REQUESTS_CPU=500m

# macOS compatibility
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"

TARGET="pyserver"
ENV="local"
TAG="poc"
SRC_DIR="targets/$TARGET/src"

echo "============================================"
echo "  Auto-Optimization Framework — POC Demo"
echo "============================================"
echo ""

# --- Reset state from previous runs ---
echo "=== Resetting previous demo state ==="
./examples/lifecycle/run-dispatcher.sh $ENV teardown.sh $TARGET 2>/dev/null || true
rm -rf results/$TARGET/

# Reset source to initial commit
if [ -d "$SRC_DIR/.git" ]; then
  cd "$SRC_DIR"
  # Delete all autoopt branches
  git branch --list 'autoopt/*' 2>/dev/null | sed 's/^[* ]*//' | while read -r b; do
    git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
    git branch -D "$b" 2>/dev/null || true
  done
  # Reset to first commit
  FIRST_COMMIT=$(git rev-list --max-parents=0 HEAD)
  git checkout -f "$FIRST_COMMIT" 2>/dev/null
  git checkout -B main 2>/dev/null || git checkout -B master 2>/dev/null
  cd - > /dev/null
fi

# --- Initialize ---
echo ""
echo "=== Initializing results ==="
mkdir -p "results/$TARGET/$ENV/logs"
echo -e "exp_id\tbranch\tparent_branch\tcommit\tmetric_name\tmetric_value\tbaseline_value\tdelta_vs_baseline\tdelta_vs_parent\tcpu_pct\tlatency_p99_ms\terror_rate\tpod_restarts\tstatus\tdescription" \
  > "results/$TARGET/$ENV/results.tsv"

# Helper: run one experiment cycle and record results
run_experiment() {
  local EXP_ID="$1"
  local DESCRIPTION="$2"
  local PARENT_BRANCH="$3"
  local LOG_PREFIX="results/$TARGET/$ENV/logs/$EXP_ID"

  echo ""
  echo "--- $EXP_ID: $DESCRIPTION ---"

  # Build
  echo "[demo] Building..."
  ./examples/lifecycle/run-dispatcher.sh $ENV build.sh $TARGET > "${LOG_PREFIX}-build.log" 2>&1

  # Deploy
  echo "[demo] Deploying..."
  ./examples/lifecycle/run-dispatcher.sh $ENV deploy.sh $TARGET > "${LOG_PREFIX}-deploy.log" 2>&1

  # Workload
  echo "[demo] Running workload..."
  ./examples/lifecycle/run-dispatcher.sh $ENV workload.sh $TARGET > "${LOG_PREFIX}-workload.log" 2>&1

  # Collect
  echo "[demo] Collecting metrics..."
  ./examples/lifecycle/run-dispatcher.sh $ENV collect.sh $TARGET > "${LOG_PREFIX}-metrics.log"

  # Validate
  echo "[demo] Validating..."
  ./examples/lifecycle/run-dispatcher.sh $ENV validate.sh $TARGET > "${LOG_PREFIX}-validate.log" 2>&1

  # Read metrics
  PEAK_RSS=$(grep "^peak_rss_mb=" "${LOG_PREFIX}-metrics.log" | cut -d= -f2)
  CPU_PCT=$(grep "^cpu_pct=" "${LOG_PREFIX}-metrics.log" | cut -d= -f2)
  LATENCY=$(grep "^latency_p99_ms=" "${LOG_PREFIX}-metrics.log" | cut -d= -f2)
  ERROR_RATE=$(grep "^error_rate=" "${LOG_PREFIX}-metrics.log" | cut -d= -f2)
  RESTARTS=$(grep "^pod_restarts=" "${LOG_PREFIX}-metrics.log" | cut -d= -f2)
  COMMIT=$(cd "$SRC_DIR" && git rev-parse --short HEAD)
  BRANCH=$(cd "$SRC_DIR" && git branch --show-current)

  echo "[demo] peak_rss_mb=$PEAK_RSS latency_p99_ms=$LATENCY"

  # Teardown
  ./examples/lifecycle/run-dispatcher.sh $ENV teardown.sh $TARGET > /dev/null 2>&1

  # Export for caller
  export LAST_PEAK_RSS="$PEAK_RSS"
  export LAST_CPU="$CPU_PCT"
  export LAST_LATENCY="$LATENCY"
  export LAST_ERROR_RATE="$ERROR_RATE"
  export LAST_RESTARTS="$RESTARTS"
  export LAST_COMMIT="$COMMIT"
  export LAST_BRANCH="$BRANCH"
}

# --- BASELINE ---
echo ""
echo "============================================"
echo "  BASELINE"
echo "============================================"
cd "$SRC_DIR"
git checkout -b "autoopt/$TARGET/$TAG-baseline" 2>/dev/null
cd - > /dev/null

run_experiment "baseline" "unmodified server" "-"

BASELINE_RSS="$LAST_PEAK_RSS"
echo -e "baseline\t$LAST_BRANCH\t-\t$LAST_COMMIT\tpeak_rss_mb\t$BASELINE_RSS\t$BASELINE_RSS\t0.0%\t0.0%\t$LAST_CPU\t$LAST_LATENCY\t$LAST_ERROR_RATE\t$LAST_RESTARTS\tkeep\tbaseline (unmodified)" \
  >> "results/$TARGET/$ENV/results.tsv"

FRONTIER="autoopt/$TARGET/$TAG-baseline"
FRONTIER_RSS="$BASELINE_RSS"

# --- EXPERIMENT 001: Cap history + shallow copy ---
echo ""
echo "============================================"
echo "  EXPERIMENT 001: cap history + shallow copy"
echo "============================================"
cd "$SRC_DIR"
git checkout "$FRONTIER"
git checkout -b "autoopt/$TARGET/$TAG-exp001"

# Apply the optimization
python3 -c "
import re
with open('server.py', 'r') as f:
    content = f.read()
content = content.replace(
    '''        # INEFFICIENCY 2: deep-copy entire DATA_STORE into HISTORY every call
        snapshot = copy.deepcopy(DATA_STORE)
        HISTORY.append(snapshot)''',
    '''        # OPTIMIZED: shallow copy, cap history to last entry only
        snapshot = DATA_STORE[:]
        HISTORY.clear()
        HISTORY.append(snapshot)'''
)
with open('server.py', 'w') as f:
    f.write(content)
"
git add -A && git commit -m "[autoopt] exp001: cap history to 1 entry, use shallow copy"
cd - > /dev/null

run_experiment "exp001" "cap history + shallow copy" "$FRONTIER"

# Decide
DELTA_BL=$(echo "scale=4; ($LAST_PEAK_RSS - $BASELINE_RSS) / $BASELINE_RSS * 100" | bc | xargs printf "%.1f")
DELTA_P=$(echo "scale=4; ($LAST_PEAK_RSS - $FRONTIER_RSS) / $FRONTIER_RSS * 100" | bc | xargs printf "%.1f")
ABS_DELTA=$(echo "$DELTA_P" | tr -d '-')
if (( $(echo "$ABS_DELTA >= 1" | bc -l) )) && (( $(echo "$DELTA_P < 0" | bc -l) )); then
  STATUS="keep"; FRONTIER="autoopt/$TARGET/$TAG-exp001"; FRONTIER_RSS="$LAST_PEAK_RSS"
  echo "[demo] DECISION: KEEP (delta ${DELTA_P}%)"
else
  STATUS="discard"
  echo "[demo] DECISION: DISCARD (delta ${DELTA_P}%)"
fi
echo -e "exp001\t$LAST_BRANCH\t$FRONTIER\t$LAST_COMMIT\tpeak_rss_mb\t$LAST_PEAK_RSS\t$BASELINE_RSS\t${DELTA_BL}%\t${DELTA_P}%\t$LAST_CPU\t$LAST_LATENCY\t$LAST_ERROR_RATE\t$LAST_RESTARTS\t$STATUS\tcap history to 1 entry, shallow copy" \
  >> "results/$TARGET/$ENV/results.tsv"

# --- EXPERIMENT 002: List to set ---
echo ""
echo "============================================"
echo "  EXPERIMENT 002: list → set for dedup"
echo "============================================"
cd "$SRC_DIR"
git checkout "$FRONTIER"
git checkout -b "autoopt/$TARGET/$TAG-exp002"

python3 -c "
with open('server.py', 'r') as f:
    content = f.read()

# Change DATA_STORE from list to set
content = content.replace('DATA_STORE = []', 'DATA_STORE = set()')

# Replace _handle_ingest
content = content.replace(
    '''        body = self._read_body()
        items = json.loads(body).get('items', [])
        added = 0
        for item in items:
            # INEFFICIENCY 1: O(n) membership check on list
            if item not in DATA_STORE:
                DATA_STORE.append(item)
                added += 1
        self._respond(200, {'added': added, 'total': len(DATA_STORE)})''',
    '''        body = self._read_body()
        items = json.loads(body).get('items', [])
        before = len(DATA_STORE)
        DATA_STORE.update(items)
        added = len(DATA_STORE) - before
        self._respond(200, {'added': added, 'total': len(DATA_STORE)})'''
)

# Fix _handle_process: list() instead of [:] for sets
content = content.replace('snapshot = DATA_STORE[:]', 'snapshot = list(DATA_STORE)')

with open('server.py', 'w') as f:
    f.write(content)
"
git add -A && git commit -m "[autoopt] exp002: replace list with set for O(1) dedup"
cd - > /dev/null

run_experiment "exp002" "list to set for dedup" "$FRONTIER"

DELTA_BL=$(echo "scale=4; ($LAST_PEAK_RSS - $BASELINE_RSS) / $BASELINE_RSS * 100" | bc | xargs printf "%.1f")
DELTA_P=$(echo "scale=4; ($LAST_PEAK_RSS - $FRONTIER_RSS) / $FRONTIER_RSS * 100" | bc | xargs printf "%.1f")
ABS_DELTA=$(echo "$DELTA_P" | tr -d '-')
if (( $(echo "$ABS_DELTA >= 1" | bc -l) )) && (( $(echo "$DELTA_P < 0" | bc -l) )); then
  STATUS="keep"; FRONTIER="autoopt/$TARGET/$TAG-exp002"; FRONTIER_RSS="$LAST_PEAK_RSS"
  echo "[demo] DECISION: KEEP (delta ${DELTA_P}%)"
else
  STATUS="discard"
  echo "[demo] DECISION: DISCARD (delta ${DELTA_P}%)"
fi
echo -e "exp002\t$LAST_BRANCH\t$FRONTIER\t$LAST_COMMIT\tpeak_rss_mb\t$LAST_PEAK_RSS\t$BASELINE_RSS\t${DELTA_BL}%\t${DELTA_P}%\t$LAST_CPU\t$LAST_LATENCY\t$LAST_ERROR_RATE\t$LAST_RESTARTS\t$STATUS\tlist to set for O(1) dedup" \
  >> "results/$TARGET/$ENV/results.tsv"

# --- EXPERIMENT 003: Generators for stats ---
echo ""
echo "============================================"
echo "  EXPERIMENT 003: generators + heapq"
echo "============================================"
cd "$SRC_DIR"
git checkout "$FRONTIER"
git checkout -b "autoopt/$TARGET/$TAG-exp003"

python3 -c "
with open('server.py', 'r') as f:
    content = f.read()

content = content.replace(
    '''    def _handle_stats(self):
        # INEFFICIENCY 3: materialize full intermediate lists
        numerics = [x for x in DATA_STORE if isinstance(x, (int, float))]
        doubled = [x * 2 for x in numerics]
        sorted_vals = sorted(doubled)
        top_100 = sorted_vals[-100:] if len(sorted_vals) > 100 else sorted_vals
        self._respond(200, {
            'count': len(numerics),
            'top_100_sum': sum(top_100),
            'max': max(doubled) if doubled else 0
        })''',
    '''    def _handle_stats(self):
        # OPTIMIZED: use generators and heapq
        import heapq
        numerics = (x for x in DATA_STORE if isinstance(x, (int, float)))
        doubled = (x * 2 for x in numerics)
        top_100 = heapq.nlargest(100, doubled)
        count = sum(1 for x in DATA_STORE if isinstance(x, (int, float)))
        self._respond(200, {
            'count': count,
            'top_100_sum': sum(top_100),
            'max': max(top_100) if top_100 else 0
        })'''
)

with open('server.py', 'w') as f:
    f.write(content)
"
git add -A && git commit -m "[autoopt] exp003: generators + heapq for stats"
cd - > /dev/null

run_experiment "exp003" "generators + heapq" "$FRONTIER"

DELTA_BL=$(echo "scale=4; ($LAST_PEAK_RSS - $BASELINE_RSS) / $BASELINE_RSS * 100" | bc | xargs printf "%.1f")
DELTA_P=$(echo "scale=4; ($LAST_PEAK_RSS - $FRONTIER_RSS) / $FRONTIER_RSS * 100" | bc | xargs printf "%.1f")
ABS_DELTA=$(echo "$DELTA_P" | tr -d '-')
if (( $(echo "$ABS_DELTA >= 1" | bc -l) )) && (( $(echo "$DELTA_P < 0" | bc -l) )); then
  STATUS="keep"; FRONTIER="autoopt/$TARGET/$TAG-exp003"; FRONTIER_RSS="$LAST_PEAK_RSS"
  echo "[demo] DECISION: KEEP (delta ${DELTA_P}%)"
else
  STATUS="discard"
  echo "[demo] DECISION: DISCARD (delta ${DELTA_P}% below 1% threshold)"
fi
echo -e "exp003\t$LAST_BRANCH\t$FRONTIER\t$LAST_COMMIT\tpeak_rss_mb\t$LAST_PEAK_RSS\t$BASELINE_RSS\t${DELTA_BL}%\t${DELTA_P}%\t$LAST_CPU\t$LAST_LATENCY\t$LAST_ERROR_RATE\t$LAST_RESTARTS\t$STATUS\tgenerators + heapq for stats" \
  >> "results/$TARGET/$ENV/results.tsv"

# --- SUMMARY ---
echo ""
echo "============================================"
echo "  RESULTS"
echo "============================================"
echo ""
echo "Frontier: $FRONTIER"
echo "Baseline RSS: ${BASELINE_RSS} MB"
echo "Final RSS: ${FRONTIER_RSS} MB"
echo ""
echo "Experiment log:"
cat "results/$TARGET/$ENV/results.tsv" | cut -f1,6,8,9,14,15 | column -t -s$'\t'
echo ""
echo "Full results: results/$TARGET/$ENV/results.tsv"
echo "Branches:"
cd "$SRC_DIR" && git branch --list 'autoopt/*' && cd - > /dev/null
echo ""
echo "Done! Run './examples/demo/teardown.sh' to clean up."
