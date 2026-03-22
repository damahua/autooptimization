# Auto-Optimization Framework — Technical Design Spec

**Date:** 2026-03-22
**Status:** Draft
**Inspired by:** [karpathy/autoresearch](https://github.com/karpathy/autoresearch)

---

## 1. Overview

An autonomous AI agent framework that optimizes production code for memory usage, CPU usage, cache performance, and other system metrics. The agent scans source code, identifies optimization opportunities, makes changes, deploys to Kubernetes, runs workloads with profiling, validates results, and iterates — keeping improvements and discarding regressions.

Core pattern: **scan → modify → build → deploy → workload → collect → analyze → keep/discard → repeat.**

Key properties:
- **Language-agnostic** — OS/container-level profiling works for C++, Java, Python, Go, etc.
- **Environment-agnostic** — same loop runs against local kind, staging, or prod K8s clusters
- **Target-agnostic** — pluggable target configs; adding a new project = adding a folder
- **Shell-script-based** — no Python orchestrator, no framework runtime; AI agent calls scripts directly (pure autoresearch pattern)

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        AI Agent (Claude Code / Codex)           │
│  Reads program.md → drives the loop → makes optimization       │
│  decisions → edits code → calls scripts → analyzes results      │
└──────────────┬──────────────────────────────────────────────────┘
               │ shell commands
               ▼
┌─────────────────────────────────────────────────────────────────┐
│                     run.sh (Dispatcher)                         │
│  Resolves env overlay → sources env.conf → executes script      │
└──────────────┬──────────────────────────────────────────────────┘
               │
    ┌──────────┼──────────┬──────────┬──────────┬─────────┐
    ▼          ▼          ▼          ▼          ▼         ▼
 build.sh  deploy.sh  workload.sh collect.sh teardown.sh cleanup.sh
    │          │          │          │          │
    ▼          ▼          ▼          ▼          ▼
 Docker     K8s API    Target     K8s API    K8s API
 daemon     (kubectl)  service    /proc      (kubectl)
                       (HTTP/     perf
                        gRPC/     prometheus
                        SQL)      datadog
```

**Data flow:**

```
target source code ──→ Docker image ──→ K8s Pod ──→ workload traffic
                                            │
                                            ▼
                                     metrics.log ──→ results.tsv + summary.md
                                            │
                                            ▼
                                     keep/discard decision ──→ git branch management
```

---

## 3. Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Language support | Stack-agnostic (OS/container-level profiling) | Same framework for any language |
| K8s setup | Local first (kind), swappable to remote | Fast iteration, easy to set up |
| Discovery method | Hybrid: code scan + optional human hints | Balance autonomy with domain knowledge |
| Success metric | Single primary metric per run | Clean keep/discard decision, like autoresearch |
| Repo structure | Framework repo + target source as plain clones (.gitignore'd) | Framework stays small, target source independent |
| Agent instructions | Minimal with optional hints section | Easy to start, incrementally add domain knowledge |
| First target | ClickHouse (C++) | Large codebase, clear optimization surface |
| Architecture | Shell scripts + AI agent | Pure autoresearch pattern, minimal moving parts |

---

## 4. Agent Runtime

### 4.1 What the Agent Is

The agent is an AI coding assistant (Claude Code, Codex, or similar) with direct shell access. It is NOT a custom program — it is a human-operated AI tool that follows instructions from `program.md`.

### 4.2 Launch Protocol

```bash
# Human starts the agent in the framework directory
cd /path/to/autooptimization

# Human tells the agent:
"Read program.md. Target: clickhouse. Environment: local.
 Primary metric: peak_rss_mb. Tag: mar22. Go."
```

### 4.3 Agent Capabilities

| Capability | How |
|-----------|-----|
| Read files | Direct file access |
| Edit source code | AI-native code editing |
| Run shell commands | `./run.sh`, `git`, `grep`, `cat`, etc. |
| Analyze results | Read metrics.log, compare numbers |
| Make decisions | Keep/discard based on metric + constraints |
| Generate summaries | Write summary.md after each experiment |

### 4.4 Crash Recovery & Resume Protocol

All state is persisted to disk — nothing is in-memory only.

**State artifacts:**
- `results/<target>/<env>/results.tsv` — full experiment history
- `results/<target>/<env>/summary.md` — human-readable summary
- `results/<target>/<env>/status.json` — current experiment state (see §11 Observability)
- Git branches in `targets/<target>/src/` — code state for every experiment

**Resume steps (agent performs on restart):**

```bash
# 1. Find the last experiment
cd targets/<target>/src
LAST_EXP=$(tail -1 ../../results/<target>/<env>/results.tsv | cut -f1)

# 2. Find the current frontier (last "keep" branch)
FRONTIER=$(grep "keep" ../../results/<target>/<env>/results.tsv | tail -1 | cut -f2)

# 3. If FRONTIER is empty, fall back to baseline
if [ -z "$FRONTIER" ]; then
  FRONTIER="autoopt/<target>/<tag>-baseline"
fi

# 4. Checkout the frontier
git checkout "$FRONTIER"

# 5. Compute next experiment number
NEXT_NUM=$(printf "%03d" $((${LAST_EXP##*exp} + 1)))

# 6. Continue the loop
```

**Edge cases:**
- If `results.tsv` has only the header → no experiments yet, start from baseline
- If the last experiment has status `in_progress` → it was interrupted; teardown any leftover K8s resources, mark as `crash` in results.tsv, continue
- If the agent can't determine state → ask the human

---

## 5. Repository Structure

```
autooptimization/
├── program.md                           # agent instructions (the loop, rules, formats)
├── run.sh                               # dispatcher: ./run.sh <env> <script> <target>
├── .gitignore                           # excludes targets/*/src/, results/, *.log
│
├── envs/                                # environment overlay system
│   ├── base/                            # default implementations
│   │   ├── env.conf                     # shared defaults (timeouts, thresholds)
│   │   ├── build.sh                     # docker build + tag
│   │   ├── deploy.sh                    # kubectl apply + wait + port-forward
│   │   ├── workload.sh                  # delegate to target's workload.sh
│   │   ├── collect.sh                   # kubectl top + /proc metrics
│   │   ├── teardown.sh                  # kubectl delete + cleanup
│   │   ├── cleanup.sh                   # remove branches + resources
│   │   └── validate.sh                  # run target's test suite
│   ├── local/
│   │   ├── env.conf                     # kind-specific config
│   │   └── build.sh                     # override: kind load instead of push
│   ├── staging/
│   │   ├── env.conf                     # staging cluster config
│   │   └── collect.sh                   # override: prometheus-based collection
│   ├── prod/
│   │   ├── env.conf                     # prod safety config
│   │   └── collect.sh                   # override: datadog-based collection
│   └── prod-eu/
│       ├── env.conf                     # prod-eu config
│       └── deploy.sh                    # override: eu-specific node affinity
│
├── targets/                             # one subdirectory per target project
│   └── clickhouse/
│       ├── target.md                    # project config: repo, metric, scope, constraints
│       ├── hints.md                     # optional human domain knowledge
│       ├── Dockerfile                   # how to build this target
│       ├── k8s.yaml                     # K8s deployment + service manifest
│       ├── workload.sh                  # target-specific test workload
│       ├── validate.sh                  # target-specific tests/checks (optional)
│       └── src/                         # git clone of target source (.gitignore'd)
│
└── results/                             # experiment results, per-target per-env
    └── clickhouse/
        └── local/
            ├── results.tsv              # full experiment log
            ├── summary.md               # agent-generated summary
            ├── status.json              # current experiment state
            └── logs/                    # per-experiment log files
                ├── exp001-metrics.log
                ├── exp001-build.log
                ├── exp002-metrics.log
                └── ...
```

### 5.1 .gitignore

```
# Target source code (each is its own git repo)
targets/*/src/

# Experiment results (generated)
results/

# Runtime artifacts
*.log
/tmp/autoopt-*
```

---

## 6. Component Specifications

### 6.1 run.sh — Dispatcher

**Purpose:** Resolve environment overlay and execute the correct script.

**Interface:**
```
Usage:  ./run.sh <env> <script> <target>
Args:   env     — environment name (local, staging, prod, prod-eu)
        script  — script name (build.sh, deploy.sh, workload.sh, collect.sh, teardown.sh, cleanup.sh, validate.sh, profile.sh)
        target  — target name (clickhouse, kafka, etc.)
Exit:   passes through the exit code of the executed script
Env:    all variables from base/env.conf + <env>/env.conf are exported
```

**Implementation:**

```bash
#!/bin/bash
set -euo pipefail

ENV="${1:?Usage: ./run.sh <env> <script> <target>}"
SCRIPT="${2:?Usage: ./run.sh <env> <script> <target>}"
TARGET="${3:?Usage: ./run.sh <env> <script> <target>}"

FRAMEWORK_ROOT="$(cd "$(dirname "$0")" && pwd)"
export FRAMEWORK_ROOT TARGET ENV

# Validate inputs
if [ ! -d "$FRAMEWORK_ROOT/envs/$ENV" ]; then
  echo "[run.sh] ERROR: Environment '$ENV' not found in envs/" >&2; exit 1
fi
if [ ! -d "$FRAMEWORK_ROOT/targets/$TARGET" ]; then
  echo "[run.sh] ERROR: Target '$TARGET' not found in targets/" >&2; exit 1
fi
if [ ! -f "$FRAMEWORK_ROOT/envs/$ENV/$SCRIPT" ] && [ ! -f "$FRAMEWORK_ROOT/envs/base/$SCRIPT" ]; then
  echo "[run.sh] ERROR: Script '$SCRIPT' not found in envs/$ENV/ or envs/base/" >&2; exit 1
fi

# Source env.conf: base first, then env-specific override
source "$FRAMEWORK_ROOT/envs/base/env.conf"
if [ -f "$FRAMEWORK_ROOT/envs/$ENV/env.conf" ]; then
  source "$FRAMEWORK_ROOT/envs/$ENV/env.conf"
fi

# Resolve script: env-specific if exists, otherwise base
if [ -f "$FRAMEWORK_ROOT/envs/$ENV/$SCRIPT" ]; then
  exec "$FRAMEWORK_ROOT/envs/$ENV/$SCRIPT" "$TARGET"
else
  exec "$FRAMEWORK_ROOT/envs/base/$SCRIPT" "$TARGET"
fi
```

**Validation:**
- Exits with error if `<env>` directory doesn't exist under `envs/`
- Exits with error if `<script>` doesn't exist in either `envs/<env>/` or `envs/base/`
- Exits with error if `<target>` directory doesn't exist under `targets/`

---

### 6.2 envs/base/env.conf — Default Configuration

```bash
# === Kubernetes ===
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-autoopt}"
NAMESPACE="${NAMESPACE:-autoopt}"

# === Container Registry ===
REGISTRY="${REGISTRY:-local}"          # "local" = kind load, anything else = docker push
IMAGE_TAG="${IMAGE_TAG:-latest}"

# === Resource Limits (for K8s pod) ===
RESOURCE_LIMITS_CPU="${RESOURCE_LIMITS_CPU:-2}"
RESOURCE_LIMITS_MEMORY="${RESOURCE_LIMITS_MEMORY:-8Gi}"
RESOURCE_REQUESTS_CPU="${RESOURCE_REQUESTS_CPU:-1}"
RESOURCE_REQUESTS_MEMORY="${RESOURCE_REQUESTS_MEMORY:-4Gi}"

# === Timeouts (seconds) ===
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"           # 10 min
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-300}"          # 5 min
WORKLOAD_TIMEOUT="${WORKLOAD_TIMEOUT:-600}"       # 10 min
COLLECT_TIMEOUT="${COLLECT_TIMEOUT:-60}"          # 1 min
EXPERIMENT_TIMEOUT="${EXPERIMENT_TIMEOUT:-1800}"  # 30 min total per experiment

# === Metric Collection ===
COLLECT_METHOD="${COLLECT_METHOD:-kubectl}"       # kubectl, prometheus, datadog
COLLECT_INTERVAL="${COLLECT_INTERVAL:-5}"         # seconds between samples during workload

# === Safety ===
SAFETY_LEVEL="${SAFETY_LEVEL:-autonomous}"        # autonomous, approval_required
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"
MAX_REGRESSION_PCT="${MAX_REGRESSION_PCT:-50}"    # stop if any metric regresses more than this

# === Workload ===
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"           # wait after deploy before workload
WORKLOAD_RUNS="${WORKLOAD_RUNS:-3}"              # run workload N times, take median
MIN_IMPROVEMENT_PCT="${MIN_IMPROVEMENT_PCT:-1}"   # changes below this threshold are noise → discard
```

---

### 6.3 build.sh — Build Target Image

**Purpose:** Build a Docker image from target source code.

**Interface:**
```
Input:  $TARGET, $FRAMEWORK_ROOT, env vars from env.conf
Output: Docker image tagged as autoopt-$TARGET:$IMAGE_TAG
Exit:   0 = success, 1 = build failure
Logs:   stdout/stderr → captured by agent to results/<target>/<env>/logs/exp<NNN>-build.log
```

**Steps (base implementation):**

```bash
#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

echo "[build] Building autoopt-$TARGET:$IMAGE_TAG"
echo "[build] Dockerfile: $TARGET_DIR/Dockerfile"
echo "[build] Context: $TARGET_DIR/src"

# 1. Build image with timeout
timeout "$BUILD_TIMEOUT" docker build \
  -t "autoopt-$TARGET:$IMAGE_TAG" \
  -f "$TARGET_DIR/Dockerfile" \
  "$TARGET_DIR/src"

# 2. Load into registry
if [ "$REGISTRY" = "local" ]; then
  # kind: load image directly
  kind load docker-image "autoopt-$TARGET:$IMAGE_TAG" --name autoopt 2>/dev/null || true
else
  # Remote: tag and push
  docker tag "autoopt-$TARGET:$IMAGE_TAG" "$REGISTRY/autoopt-$TARGET:$IMAGE_TAG"
  docker push "$REGISTRY/autoopt-$TARGET:$IMAGE_TAG"
fi

echo "[build] Done. Image: autoopt-$TARGET:$IMAGE_TAG"
```

**Error handling:**
- `timeout` kills the build if it exceeds `BUILD_TIMEOUT`
- Exit code 124 from `timeout` → build timed out (agent should discard experiment)
- Non-zero exit from `docker build` → build failed (agent should check build.log for errors)

---

### 6.4 deploy.sh — Deploy to Kubernetes

**Purpose:** Deploy the built image to K8s, wait for it to be ready, set up access.

**Interface:**
```
Input:  $TARGET, $FRAMEWORK_ROOT, env vars from env.conf
Output: Running pod accessible via port-forward or service
Exit:   0 = pod ready, 1 = deploy failure
Stdout: SERVICE_HOST=localhost
        SERVICE_PORT=<forwarded-port>
```

**Steps (base implementation):**

```bash
#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

echo "[deploy] Deploying autoopt-$TARGET to namespace $NAMESPACE"

# 1. Ensure namespace exists
kubectl --context "$KUBE_CONTEXT" create namespace "$NAMESPACE" 2>/dev/null || true

# 2. Apply manifests (envsubst for dynamic values)
export IMAGE_NAME="autoopt-$TARGET:$IMAGE_TAG"
envsubst < "$TARGET_DIR/k8s.yaml" | \
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" apply -f -

# 3. Wait for pod ready
echo "[deploy] Waiting for pod ready (timeout: ${DEPLOY_TIMEOUT}s)..."
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  wait --for=condition=ready pod \
  -l "app=autoopt-$TARGET" \
  --timeout="${DEPLOY_TIMEOUT}s"

# 4. Get pod name
POD=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pod -l "app=autoopt-$TARGET" -o jsonpath='{.items[0].metadata.name}')
echo "[deploy] Pod ready: $POD"

# 5. Port-forward in background
LOCAL_PORT=$(shuf -i 30000-39999 -n 1)
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  port-forward "pod/$POD" "$LOCAL_PORT:${TARGET_SERVICE_PORT:-8080}" &
PF_PID=$!
echo "$PF_PID" > "/tmp/autoopt-$TARGET-portforward.pid"

# 6. Wait for port-forward to be ready
sleep 2
if ! kill -0 "$PF_PID" 2>/dev/null; then
  echo "[deploy] ERROR: port-forward failed"
  exit 1
fi

# 7. Write connection info for workload.sh to read
cat > "/tmp/autoopt-$TARGET-connection.env" <<EOF
SERVICE_HOST=localhost
SERVICE_PORT=$LOCAL_PORT
EOF
echo "[deploy] Service available at localhost:$LOCAL_PORT"
```

**Error handling:**
- `kubectl wait` times out → exit 1, agent should check pod events: `kubectl describe pod -l app=autoopt-$TARGET`
- Pod in CrashLoopBackOff → exit 1, agent should check logs: `kubectl logs -l app=autoopt-$TARGET`
- Port-forward fails → exit 1, agent should retry or try a different port

---

### 6.5 workload.sh — Run Test Workload

**Purpose:** Delegate to the target's workload script, with timeout and warmup.

**Interface:**
```
Input:  $TARGET, $FRAMEWORK_ROOT, env vars (SERVICE_HOST, SERVICE_PORT from deploy.sh)
Output: Workload-produced metrics (latency, throughput) appended to workload-metrics.log
Exit:   0 = workload completed, 1 = workload failed/timeout
```

**Steps (base implementation):**

```bash
#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
RESULTS_DIR="$FRAMEWORK_ROOT/results/$TARGET/$ENV"

# 1. Read connection info from deploy output
if [ -f "/tmp/autoopt-$TARGET-connection.env" ]; then
  source "/tmp/autoopt-$TARGET-connection.env"
fi
export SERVICE_HOST="${SERVICE_HOST:-localhost}"
export SERVICE_PORT="${SERVICE_PORT:-8080}"

# 2. Warmup: wait for service to stabilize
echo "[workload] Warming up for ${WARMUP_SECONDS}s..."
sleep "$WARMUP_SECONDS"

# 3. Health check
echo "[workload] Health check..."
if ! timeout 10 bash -c "until curl -sf http://$SERVICE_HOST:$SERVICE_PORT/health 2>/dev/null || nc -z $SERVICE_HOST $SERVICE_PORT 2>/dev/null; do sleep 1; done"; then
  echo "[workload] ERROR: Service not responding after warmup"
  exit 1
fi

# 4. Run workload N times for statistical stability
echo "[workload] Running workload ($WORKLOAD_RUNS runs)..."
WORKLOAD_METRICS_FILE="$RESULTS_DIR/logs/workload-raw.log"
mkdir -p "$(dirname "$WORKLOAD_METRICS_FILE")"
> "$WORKLOAD_METRICS_FILE"

for i in $(seq 1 "$WORKLOAD_RUNS"); do
  echo "[workload] Run $i/$WORKLOAD_RUNS"
  set +e  # disable exit-on-error to capture exit code
  timeout "$WORKLOAD_TIMEOUT" "$TARGET_DIR/workload.sh" >> "$WORKLOAD_METRICS_FILE" 2>&1
  WORKLOAD_EXIT=$?
  set -e
  if [ $WORKLOAD_EXIT -ne 0 ]; then
    echo "[workload] WARNING: Run $i failed (exit $WORKLOAD_EXIT)"
  fi
done

echo "[workload] Done. Raw results in $WORKLOAD_METRICS_FILE"
```

**Error handling:**
- Service not responding after warmup → exit 1, agent checks pod logs
- `timeout` kills workload → exit 124, agent marks as timeout failure
- Workload script returns non-zero → logged as warning, continues remaining runs

---

### 6.6 collect.sh — Collect Metrics

**Purpose:** Gather OS/container-level metrics from the running pod and combine with workload metrics.

**Interface:**
```
Input:  $TARGET, $FRAMEWORK_ROOT, env vars
Output: Metrics in key=value format to stdout (one per line)
Exit:   0 = collection succeeded, 1 = collection failed
Format: peak_rss_mb=3850.1
        cpu_pct=73.0
        latency_p99_ms=46.0
        throughput_qps=12500
```

**ALL collect.sh implementations (kubectl, prometheus, datadog) MUST produce this exact output format.** The agent parses metrics with `grep "^<metric_name>=" metrics.log | cut -d= -f2`.

**Steps (base/kubectl implementation):**

```bash
#!/bin/bash
set -euo pipefail
TARGET="$1"
RESULTS_DIR="$FRAMEWORK_ROOT/results/$TARGET/$ENV"

POD=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pod -l "app=autoopt-$TARGET" -o jsonpath='{.items[0].metadata.name}')

# === Container-level metrics (language-agnostic) ===

# 1. Peak RSS from /proc (VmHWM = high water mark)
VM_HWM_KB=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  exec "$POD" -- cat /proc/1/status 2>/dev/null | grep VmHWM | awk '{print $2}')
PEAK_RSS_MB=$(echo "scale=1; ${VM_HWM_KB:-0} / 1024" | bc)

# 2. Current RSS
VM_RSS_KB=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  exec "$POD" -- cat /proc/1/status 2>/dev/null | grep VmRSS | awk '{print $2}')
CURRENT_RSS_MB=$(echo "scale=1; ${VM_RSS_KB:-0} / 1024" | bc)

# 3. CPU from kubectl top
CPU_RAW=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  top pod "$POD" --no-headers 2>/dev/null | awk '{print $2}')
# Convert millicores to percentage of limit
CPU_MILLICORES="${CPU_RAW%m}"
CPU_LIMIT_MILLICORES=$((RESOURCE_LIMITS_CPU * 1000))
CPU_PCT=$(echo "scale=1; ${CPU_MILLICORES:-0} * 100 / $CPU_LIMIT_MILLICORES" | bc)

# 4. Memory from kubectl top (as cross-check)
MEM_RAW=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  top pod "$POD" --no-headers 2>/dev/null | awk '{print $3}')

# 5. Pod uptime (seconds)
START_TIME=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pod "$POD" -o jsonpath='{.status.startTime}')
# Portable date parsing: try GNU date, then macOS date, then Python fallback
START_EPOCH=$(date -d "$START_TIME" +%s 2>/dev/null \
  || date -jf "%Y-%m-%dT%H:%M:%SZ" "$START_TIME" +%s 2>/dev/null \
  || python3 -c "import datetime; print(int(datetime.datetime.fromisoformat('$START_TIME'.replace('Z','+00:00')).timestamp()))" 2>/dev/null \
  || echo 0)
UPTIME_SECONDS=$(( $(date +%s) - START_EPOCH ))

# 6. Pod restart count
RESTART_COUNT=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)

# === Workload metrics (from workload.sh output) ===
WORKLOAD_LOG="$RESULTS_DIR/logs/workload-raw.log"
if [ -f "$WORKLOAD_LOG" ]; then
  # Extract latency p99 (median across runs)
  LATENCY_P99=$(grep "latency_p99_ms=" "$WORKLOAD_LOG" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
  # Extract throughput (median across runs)
  THROUGHPUT=$(grep "throughput_qps=" "$WORKLOAD_LOG" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
  # Extract error rate
  ERROR_RATE=$(grep "error_rate=" "$WORKLOAD_LOG" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
fi

# === Output in standard format ===
echo "peak_rss_mb=${PEAK_RSS_MB}"
echo "current_rss_mb=${CURRENT_RSS_MB}"
echo "cpu_pct=${CPU_PCT}"
echo "kubectl_mem=${MEM_RAW:-unknown}"
echo "latency_p99_ms=${LATENCY_P99:-0}"
echo "throughput_qps=${THROUGHPUT:-0}"
echo "error_rate=${ERROR_RATE:-0}"
echo "pod_restarts=${RESTART_COUNT}"
echo "pod_uptime_seconds=${UPTIME_SECONDS}"
```

**Prometheus override (staging/collect.sh) queries:**
```bash
# Instead of kubectl exec + /proc, query prometheus
PEAK_RSS_MB=$(curl -s "http://$PROMETHEUS_URL/api/v1/query?query=container_memory_max_usage_bytes{pod=~'autoopt-$TARGET.*'}/1024/1024" | jq '.data.result[0].value[1]' -r)
```

**Datadog override (prod/collect.sh) queries:**
```bash
# Query datadog API for pod metrics
PEAK_RSS_MB=$(curl -s -H "DD-API-KEY: $DD_API_KEY" "https://api.datadoghq.com/api/v1/query?query=max:kubernetes.memory.rss{pod_name:autoopt-$TARGET*}.rollup(max)" | jq '.series[0].pointlist[-1][1]' -r)
```

---

### 6.7 validate.sh — Run Correctness Tests

**Purpose:** Run the target's test suite to ensure the optimization didn't break functionality.

**Interface:**
```
Input:  $TARGET, $FRAMEWORK_ROOT, env vars
Output: Test results to stdout
Exit:   0 = all tests pass, 1 = tests failed
```

**Steps (base implementation):**

```bash
#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

echo "[validate] Running validation for $TARGET..."

# 1. Run target-specific validation if it exists
if [ -f "$TARGET_DIR/validate.sh" ]; then
  echo "[validate] Running target-specific validation..."
  "$TARGET_DIR/validate.sh"
  VALIDATE_EXIT=$?
  if [ $VALIDATE_EXIT -ne 0 ]; then
    echo "[validate] FAILED: target validation returned $VALIDATE_EXIT"
    exit 1
  fi
fi

# 2. Check pod health after workload
POD=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pod -l "app=autoopt-$TARGET" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$POD" ]; then
  RESTART_COUNT=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)

  if [ "$RESTART_COUNT" -gt 0 ]; then
    echo "[validate] WARNING: Pod restarted $RESTART_COUNT times during experiment"
    echo "[validate] FAILED: pod instability detected"
    exit 1
  fi

  PHASE=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)

  if [ "$PHASE" != "Running" ]; then
    echo "[validate] FAILED: pod is in phase $PHASE (expected Running)"
    exit 1
  fi
fi

echo "[validate] PASSED"
```

---

### 6.8 teardown.sh — Clean Up Experiment

**Purpose:** Remove K8s resources from the experiment, free cluster capacity for next run.

**Interface:**
```
Input:  $TARGET, $FRAMEWORK_ROOT, env vars
Output: none
Exit:   0 = cleanup done, 1 = cleanup failed (non-fatal, agent can continue)
```

**Steps (base implementation):**

```bash
#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

echo "[teardown] Tearing down autoopt-$TARGET in namespace $NAMESPACE"

# 1. Kill port-forward
if [ -f "/tmp/autoopt-$TARGET-portforward.pid" ]; then
  PF_PID=$(cat "/tmp/autoopt-$TARGET-portforward.pid")
  kill "$PF_PID" 2>/dev/null || true
  rm -f "/tmp/autoopt-$TARGET-portforward.pid"
fi

# 2. Delete K8s resources
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  delete -f "$TARGET_DIR/k8s.yaml" --ignore-not-found --timeout=60s

# 3. Wait for pod termination
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  wait --for=delete pod -l "app=autoopt-$TARGET" --timeout=60s 2>/dev/null || true

# 4. Clean up connection env file
rm -f "/tmp/autoopt-$TARGET-connection.env"

echo "[teardown] Done."
```

---

### 6.9 cleanup.sh — Full Cleanup

**Purpose:** Remove all experiment branches, K8s resources, and optionally results for a target+tag.

**Interface:**
```
Usage:  ./run.sh <env> cleanup.sh <target> [--tag <tag>] [--all]
        --tag <tag>   only clean branches matching this tag (default: all)
        --all         also delete results.tsv, summary.md, and logs
```

**Steps (base implementation):**

```bash
#!/bin/bash
set -euo pipefail
TARGET="$1"; shift
TAG=""
CLEAN_ALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --all) CLEAN_ALL=true; shift ;;
    *) shift ;;
  esac
done

TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"
RESULTS_DIR="$FRAMEWORK_ROOT/results/$TARGET/$ENV"

echo "[cleanup] Cleaning up $TARGET (tag: ${TAG:-all}, env: $ENV)"

# 1. Teardown any running K8s resources
"$FRAMEWORK_ROOT/envs/base/teardown.sh" "$TARGET" 2>/dev/null || true

# 2. Delete experiment branches from target source repo
if [ -d "$TARGET_DIR/src/.git" ]; then
  cd "$TARGET_DIR/src"
  PATTERN="autoopt/$TARGET/${TAG:-*}"
  BRANCHES=$(git branch --list "$PATTERN" 2>/dev/null | sed 's/^[* ]*//')
  if [ -n "$BRANCHES" ]; then
    echo "$BRANCHES" | while read -r branch; do
      echo "[cleanup] Deleting branch: $branch"
      git branch -D "$branch" 2>/dev/null || true
    done
  fi
  git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
  cd "$FRAMEWORK_ROOT"
fi

# 3. Remove Docker images
docker rmi "autoopt-$TARGET:$IMAGE_TAG" 2>/dev/null || true
if [ "$REGISTRY" != "local" ]; then
  docker rmi "$REGISTRY/autoopt-$TARGET:$IMAGE_TAG" 2>/dev/null || true
fi

# 4. Optionally remove results
if [ "$CLEAN_ALL" = true ] && [ -d "$RESULTS_DIR" ]; then
  echo "[cleanup] Removing results: $RESULTS_DIR"
  rm -rf "$RESULTS_DIR"
fi

echo "[cleanup] Done."
```

---

### 6.10 profile.sh — Profiling Orchestrator

**Purpose:** Delegate to the target's profiling script, then generate flame graphs from the folded stack output using tools/FlameGraph.

**Interface:**
```
Usage:  ./run.sh <env> profile.sh <target>
Input:  $TARGET, $FRAMEWORK_ROOT, $ENV, env vars from env.conf
        PROFILE_TYPE=cpu|memory|both (optional, default: both)
Output: results/<target>/<env>/profiles/*.folded
        results/<target>/<env>/profiles/*_flamegraph.svg
        results/<target>/<env>/profiles/profiling_summary.txt
Exit:   0 = success or no profile.sh found (graceful skip)
        non-zero = target profiling failed
```

**Prerequisite:** `tools/FlameGraph/` must exist (see setup below). If absent, flame graph generation is skipped with a warning.

```bash
# Install FlameGraph (one-time)
git clone https://github.com/brendangregg/FlameGraph.git tools/FlameGraph
```

**Target profile.sh contract:**

Each target provides `targets/<target>/profile.sh`. The framework passes these env vars:

| Variable | Description |
|----------|-------------|
| `SERVICE_HOST` | Host of the running service |
| `SERVICE_PORT` | Port of the running service |
| `PROFILE_TYPE` | `cpu`, `memory`, or `both` |
| `PROFILE_DIR` | Directory to write output files |

The target script must write:
- `$PROFILE_DIR/<name>.folded` — folded stack format (`frame1;frame2;...;frameN count`)
- `$PROFILE_DIR/profiling_summary.txt` — human-readable summary

The framework's `envs/base/profile.sh` generates `*_flamegraph.svg` files automatically from every `.folded` file found in `PROFILE_DIR`.

**When to run:**
- After baseline workload, before starting experiments
- After each KEEP experiment to see how hot paths shifted

---

## 7. The Experiment Loop — Step by Step

This is the core of the framework. Every step is detailed with exact commands, inputs, outputs, error handling, and decision logic.

### 7.0 Prerequisites

Before the loop starts:

```bash
# Agent verifies environment
which docker kubectl kind git || echo "MISSING: required tools"
kubectl --context "$KUBE_CONTEXT" cluster-info || echo "MISSING: K8s cluster"
docker info || echo "MISSING: Docker daemon"

# Agent clones target source (if not already present)
if [ ! -d "targets/$TARGET/src/.git" ]; then
  REPO_URL=$(grep "^repo:" "targets/$TARGET/target.md" | awk '{print $2}')
  BRANCH=$(grep "^branch:" "targets/$TARGET/target.md" | awk '{print $2}')
  git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "targets/$TARGET/src"
fi

# Agent initializes results directory
mkdir -p "results/$TARGET/$ENV/logs"
if [ ! -f "results/$TARGET/$ENV/results.tsv" ]; then
  echo -e "exp_id\tbranch\tparent_branch\tcommit\tmetric_name\tmetric_value\tbaseline_value\tdelta_vs_baseline\tdelta_vs_parent\tcpu_pct\tlatency_p99_ms\terror_rate\tpod_restarts\tstatus\tdescription" > "results/$TARGET/$ENV/results.tsv"
fi
```

### 7.1 Step: Establish Baseline

**Purpose:** Run the unmodified target to establish the reference metric.

```
Agent actions:
  1. cd targets/$TARGET/src
  2. git checkout -b autoopt/$TARGET/$TAG-baseline
  3. ./run.sh $ENV build.sh $TARGET       > ../../../results/$TARGET/$ENV/logs/baseline-build.log 2>&1
  4. ./run.sh $ENV deploy.sh $TARGET      > ../../../results/$TARGET/$ENV/logs/baseline-deploy.log 2>&1
  5. ./run.sh $ENV workload.sh $TARGET    > ../../../results/$TARGET/$ENV/logs/baseline-workload.log 2>&1
  6. ./run.sh $ENV collect.sh $TARGET     > ../../../results/$TARGET/$ENV/logs/baseline-metrics.log
  7. ./run.sh $ENV validate.sh $TARGET    > ../../../results/$TARGET/$ENV/logs/baseline-validate.log 2>&1
  8. ./run.sh $ENV teardown.sh $TARGET

Agent reads baseline-metrics.log:
  PRIMARY_METRIC=$(grep "^peak_rss_mb=" baseline-metrics.log | cut -d= -f2)
  BASELINE_VALUE=$PRIMARY_METRIC

Agent records in results.tsv:
  baseline	autoopt/$TARGET/$TAG-baseline	-	<commit>	peak_rss_mb	4200.3	4200.3	0.0%	0.0%	72.1	45.3	0.0	0	keep	baseline (unmodified)
```

**Failure modes:**
- Build fails → environment/Dockerfile issue, agent reports and stops
- Deploy fails → K8s issue, agent reports and stops
- Workload fails → workload script issue, agent reports and stops
- These are setup failures — the agent should NOT try to fix them silently. Report to human.

### 7.2 Step: Scan & Identify Optimization Opportunity

**Purpose:** The agent analyzes code and chooses what to optimize next.

```
Agent reads:
  1. targets/$TARGET/target.md       → knows primary metric, scope, constraints
  2. targets/$TARGET/hints.md        → knows domain hints (if present)
  3. results/$TARGET/$ENV/results.tsv → knows what's been tried before
  4. Source files in editable scope   → finds optimization opportunities

Agent considers:
  - What is the primary metric? (e.g., peak_rss_mb → focus on memory)
  - What areas are editable? (e.g., src/Storages/MergeTree/)
  - What hints exist? (e.g., "allocates heavily during merges")
  - What has already been tried? (read results.tsv descriptions)
  - What worked / didn't work in past experiments?

Agent outputs:
  - A 1-2 sentence description of the optimization idea
  - Which files will be modified
  - Expected impact (hypothesis)
```

**This step is purely AI reasoning — no scripts involved.** The agent's intelligence is the entire value here.

### 7.3 Step: Create Branch & Edit Code

**Purpose:** Create an isolated branch and implement the optimization.

```
Agent actions:
  1. Determine parent branch:
     - If this is the first experiment: parent = baseline branch
     - Otherwise: parent = last "keep" branch from results.tsv

  2. Checkout parent and create new branch:
     cd targets/$TARGET/src
     git checkout <parent_branch>
     git checkout -b autoopt/$TARGET/$TAG-exp<NNN>

  3. Edit source files to implement the optimization
     (this is AI code editing — the agent's core capability)

  4. Commit with structured message:
     git add -A
     git commit -m "[autoopt] exp<NNN>: <short description>

     Target: $TARGET
     Parent: <parent_branch>
     Hypothesis: <expected impact>"
```

**Rules:**
- Only edit files listed in `target.md` → `editable` paths
- Never edit files listed in `target.md` → `readonly` paths
- Keep changes small and focused (one optimization idea per experiment)
- If `SAFETY_LEVEL=approval_required`, pause here and show the diff to the human

### 7.4 Experiment Timeout Enforcement

The agent tracks wall-clock time for each experiment. Before each step (build, deploy, workload, collect, validate), it checks:

```
EXPERIMENT_START=$(date +%s)

# Before each step:
ELAPSED=$(( $(date +%s) - EXPERIMENT_START ))
if [ $ELAPSED -ge $EXPERIMENT_TIMEOUT ]; then
  # Experiment exceeded total timeout
  → teardown any running K8s resources
  → record as status=timeout in results.tsv
  → discard experiment, continue to next
fi
```

Individual scripts also have their own `timeout` wrappers (`BUILD_TIMEOUT`, `DEPLOY_TIMEOUT`, `WORKLOAD_TIMEOUT`). The outer experiment timeout catches cases where individual steps are within their limits but the aggregate exceeds the budget.

### 7.5 Step: Build

**Purpose:** Build a Docker image with the modified source code.

```
Agent actions:
  ./run.sh $ENV build.sh $TARGET > results/$TARGET/$ENV/logs/exp<NNN>-build.log 2>&1
  BUILD_EXIT=$?
```

**Decision tree:**
```
BUILD_EXIT == 0  → proceed to deploy
BUILD_EXIT == 124 → timeout, log as "build_timeout" in status.json
BUILD_EXIT != 0  → build error
  → Agent reads exp<NNN>-build.log for error
  → If compilation error (typo, syntax) → fix and retry (up to 3 times)
  → If dependency error → likely unfixable, discard experiment
  → If timeout → code change may have exploded build time, discard
```

### 7.6 Step: Deploy

**Purpose:** Deploy the built image to K8s and wait for it to be ready.

```
Agent actions:
  ./run.sh $ENV deploy.sh $TARGET > results/$TARGET/$ENV/logs/exp<NNN>-deploy.log 2>&1
  DEPLOY_EXIT=$?

  # Capture connection info
  grep "^SERVICE_" results/$TARGET/$ENV/logs/exp<NNN>-deploy.log > /tmp/autoopt-$TARGET-connection.env
```

**Decision tree:**
```
DEPLOY_EXIT == 0  → proceed to workload
DEPLOY_EXIT != 0  → deploy error
  → Agent checks: kubectl describe pod -l app=autoopt-$TARGET -n $NAMESPACE
  → CrashLoopBackOff → code change broke the server, check logs: kubectl logs -l app=autoopt-$TARGET
    → If obvious fix (missing config, wrong port) → fix, rebuild, retry
    → If fundamental breakage → discard experiment
  → ImagePullBackOff → build.sh didn't push correctly, retry build
  → Timeout → pod is slow to start, may be OK, check events
```

### 7.7 Step: Workload

**Purpose:** Run the test workload against the deployed service.

```
Agent actions:
  ./run.sh $ENV workload.sh $TARGET > results/$TARGET/$ENV/logs/exp<NNN>-workload.log 2>&1
  WORKLOAD_EXIT=$?
```

**Decision tree:**
```
WORKLOAD_EXIT == 0    → proceed to collect
WORKLOAD_EXIT == 124  → timeout (workload hung or service unresponsive)
  → Agent checks pod status: is pod still running? did it OOM?
  → If OOM → optimization increased memory too much, discard
  → If hung → code change introduced deadlock/infinite loop, discard
WORKLOAD_EXIT != 0    → workload error
  → Agent reads workload.log for error details
  → If connection refused → service crashed during workload, discard
  → If query errors → code change broke query handling, discard
```

### 7.8 Step: Collect Metrics

**Purpose:** Gather all metrics from the running pod.

```
Agent actions:
  ./run.sh $ENV collect.sh $TARGET > results/$TARGET/$ENV/logs/exp<NNN>-metrics.log
  COLLECT_EXIT=$?

  # Parse primary metric
  PRIMARY_VALUE=$(grep "^${PRIMARY_METRIC}=" results/$TARGET/$ENV/logs/exp<NNN>-metrics.log | cut -d= -f2)
```

**Decision tree:**
```
COLLECT_EXIT == 0 AND PRIMARY_VALUE is numeric → proceed to validate & analyze
COLLECT_EXIT != 0 OR PRIMARY_VALUE is empty    → collection failed
  → Agent retries once after 5s
  → If still fails → mark experiment as "collect_error", discard
```

### 7.9 Step: Validate

**Purpose:** Ensure the optimization didn't break correctness.

```
Agent actions:
  ./run.sh $ENV validate.sh $TARGET > results/$TARGET/$ENV/logs/exp<NNN>-validate.log 2>&1
  VALIDATE_EXIT=$?
```

**Decision tree:**
```
VALIDATE_EXIT == 0 → validation passed, proceed to analyze metrics
VALIDATE_EXIT != 0 → validation failed
  → Agent reads validate.log
  → Record as status=invalid in results.tsv
  → Discard experiment (even if metrics improved — correctness trumps performance)
```

### 7.10 Step: Analyze & Decide

**Purpose:** Compare metrics against parent and baseline, check constraints, make keep/discard decision.

```
Agent reads from metrics.log:
  PRIMARY_VALUE=3850.1
  CPU_PCT=73.0
  LATENCY_P99=46.0
  ERROR_RATE=0.0
  POD_RESTARTS=0

Agent reads direction from target.md:
  DIRECTION=lower          # "lower" = smaller is better, "higher" = larger is better

Agent computes:
  PARENT_VALUE=4100.2     # from results.tsv, the parent experiment's metric
  BASELINE_VALUE=4200.3   # from results.tsv, the baseline row

  DELTA_VS_PARENT = (PRIMARY_VALUE - PARENT_VALUE) / PARENT_VALUE * 100
  DELTA_VS_BASELINE = (PRIMARY_VALUE - BASELINE_VALUE) / BASELINE_VALUE * 100

  # "Improved" depends on direction:
  #   direction=lower  → improved means DELTA_VS_PARENT < 0 (value decreased)
  #   direction=higher → improved means DELTA_VS_PARENT > 0 (value increased)

Agent checks constraints (from target.md):
  For each constraint:
    Parse: "latency_p99_ms must not increase by more than 10% from baseline"
    BASELINE_LATENCY = 45.3 (from baseline row in results.tsv)
    CURRENT_LATENCY = 46.0
    REGRESSION = (46.0 - 45.3) / 45.3 * 100 = 1.5%
    1.5% < 10% → CONSTRAINT PASSED ✓

Agent checks safety thresholds (from env.conf):
  MAX_REGRESSION_PCT=50
  No metric regressed more than 50% → SAFETY PASSED ✓

Agent checks minimum improvement (from env.conf):
  MIN_IMPROVEMENT_PCT=1
  |DELTA_VS_PARENT| = 6.1% > 1% → above noise threshold ✓

Decision matrix:
  ┌─────────────────────┬────────────────────┬──────────────────────┬──────────┐
  │ Primary improved?   │ Constraints pass?  │ Validation pass?     │ Decision │
  ├─────────────────────┼────────────────────┼──────────────────────┼──────────┤
  │ Yes (above noise)   │ Yes                │ Yes                  │ KEEP     │
  │ Yes (above noise)   │ No                 │ Yes                  │ DISCARD  │
  │ Yes (below noise)   │ Yes                │ Yes                  │ DISCARD  │
  │ No                  │ -                  │ -                    │ DISCARD  │
  │ -                   │ -                  │ No                   │ DISCARD  │
  └─────────────────────┴────────────────────┴──────────────────────┴──────────┘
```

### 7.11 Step: Record Results

**Purpose:** Log the experiment to results.tsv and update status.json.

```
Agent appends to results.tsv (tab-separated):
  exp_id:           003
  branch:           autoopt/clickhouse/mar22-exp003
  parent_branch:    autoopt/clickhouse/mar22-exp001
  commit:           c3d4e5f
  metric_name:      peak_rss_mb
  metric_value:     3850.1
  baseline_value:   4200.3
  delta_vs_baseline: -8.3%
  delta_vs_parent:  -6.1%
  cpu_pct:          73.0
  latency_p99_ms:   46.0
  error_rate:       0.0
  pod_restarts:     0
  status:           keep
  description:      reduce MergeTree allocator block size
```

**Status values:**
- `keep` — optimization accepted, becomes new frontier
- `discard` — optimization rejected (worse metric or below noise)
- `crash` — build/deploy/workload failed
- `invalid` — validation failed (tests broke)
- `constraint_violation` — metric improved but constraint violated
- `timeout` — experiment exceeded EXPERIMENT_TIMEOUT

### 7.12 Step: Teardown

**Purpose:** Clean up K8s resources before next experiment.

```
Agent actions:
  ./run.sh $ENV teardown.sh $TARGET > results/$TARGET/$ENV/logs/exp<NNN>-teardown.log 2>&1
```

Teardown failures are non-fatal. If teardown fails, the next deploy.sh will overwrite (kubectl apply is idempotent).

### 7.13 Step: Update Summary

**Purpose:** Regenerate the human-readable summary.

The agent regenerates `results/$TARGET/$ENV/summary.md` after every experiment:

```markdown
# Auto-Optimization: ClickHouse (mar22) — local

**Generated:** 2026-03-22 14:35 UTC
**Total experiments:** 15
**Kept:** 5 | **Discarded:** 8 | **Crashed:** 2

## Best result
- **Branch:** autoopt/clickhouse/mar22-exp012
- **peak_rss_mb:** 3420.7 (↓ 18.6% from baseline 4200.3)
- **What:** combined pool allocator + decompression buffer reuse + MergeTree block size reduction

## Experiment timeline
| # | Parent | What | Metric | Δ baseline | Δ parent | Status |
|---|--------|------|--------|------------|----------|--------|
| baseline | - | unmodified | 4200.3 | - | - | keep |
| 001 | baseline | pool allocator for small objects | 4100.2 | -2.4% | -2.4% | keep |
| 002 | baseline | mmap for large blocks | 4250.0 | +1.2% | +1.2% | discard |
| 003 | 001 | reduce MergeTree block size | 3850.1 | -8.3% | -6.1% | keep |
| ... | ... | ... | ... | ... | ... | ... |

## Frontier lineage
baseline → exp001 → exp003 → exp007 → exp012 (current best)

## What worked
- Pool allocator for small objects (-2.4%)
- Reducing MergeTree allocator block size (-6.1%)
- Decompression buffer reuse (-4.2%)

## What didn't work
- mmap for large blocks: increased RSS due to page table overhead
- Replacing std::vector with arena: compilation errors, unfixable

## Constraint status
- latency_p99_ms: 48.1ms (baseline: 45.3ms, limit: 49.8ms) — within 10% ✓
- error_rate: 0.0% ✓
- pod_restarts: 0 ✓
```

### 7.14 Step: Loop Back

**Purpose:** Prepare for the next experiment.

```
Agent actions:
  1. If status was "keep":
     FRONTIER = current branch (autoopt/$TARGET/$TAG-exp<NNN>)
  2. If status was anything else:
     FRONTIER = previous frontier (unchanged)

  3. Update status.json with:
     {
       "state": "idle",
       "last_experiment": "exp003",
       "frontier_branch": "autoopt/clickhouse/mar22-exp003",
       "total_experiments": 3,
       "consecutive_failures": 0,
       "cumulative_improvement": "-8.3%"
     }

  4. Check termination conditions:
     - consecutive_failures >= MAX_CONSECUTIVE_FAILURES → stop, report to human
     - Any metric regressed > MAX_REGRESSION_PCT → stop, report to human
     - Human interrupted → stop

  5. If not terminated → go to step 7.2 (Scan & Identify)
```

---

## 8. Target Configuration — Full Specification

### 8.1 target.md Format

```markdown
# Target: <name>

## Source
repo: <git clone URL>
branch: <branch to clone>
path: targets/<name>/src

## Build
dockerfile: targets/<name>/Dockerfile
build_timeout: <seconds>

## Primary Metric
name: <metric_key from collect.sh output>
direction: lower | higher
unit: <human-readable unit>

## Secondary Metrics
- <metric_key_1>
- <metric_key_2>

## Workload
description: <what the workload does>
warmup: <seconds>s
duration: <seconds>s
script: targets/<name>/workload.sh

## Scope
editable:
  - <path/glob relative to src/>
  - <path/glob relative to src/>

readonly:
  - <path/glob relative to src/>

## Constraints
- <metric_key> must not increase|decrease by more than <N>% from baseline
- <free text constraint the agent can understand>

## Timeouts
build_timeout: <seconds>
experiment_timeout: <seconds>
```

### 8.2 hints.md Format

```markdown
# Optimization Hints: <name>

## Known hot spots
- <description of code area and why it's hot>

## Past attempts
- <what was tried before and results>

## Don't bother with
- <areas that are not worth optimizing and why>

## Architecture notes
- <relevant architecture context for the agent>
```

### 8.3 workload.sh Contract

Every target's `workload.sh` MUST:

```
Input:  SERVICE_HOST, SERVICE_PORT environment variables
Output: Metrics in key=value format to stdout:
        latency_p99_ms=<value>
        latency_p50_ms=<value>
        throughput_qps=<value>
        error_rate=<value>
        total_requests=<value>
Exit:   0 = workload completed successfully
        1 = workload failed (connection error, all queries failed)
```

Example for ClickHouse:

```bash
#!/bin/bash
set -euo pipefail

HOST="${SERVICE_HOST:-localhost}"
PORT="${SERVICE_PORT:-9000}"

# Run TPC-H queries via clickhouse-client
RESULTS=$(clickhouse-client --host "$HOST" --port "$PORT" \
  --time --format=Null \
  --queries-file /path/to/tpch-queries.sql 2>&1)

# Parse timing output and compute percentiles
# ... (target-specific parsing logic)

echo "latency_p99_ms=46.0"
echo "latency_p50_ms=22.1"
echo "throughput_qps=12500"
echo "error_rate=0.0"
echo "total_requests=50000"
```

### 8.4 k8s.yaml Template

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autoopt-${TARGET}
  labels:
    app: autoopt-${TARGET}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: autoopt-${TARGET}
  template:
    metadata:
      labels:
        app: autoopt-${TARGET}
    spec:
      containers:
      - name: ${TARGET}
        image: ${IMAGE_NAME}
        resources:
          requests:
            cpu: "${RESOURCE_REQUESTS_CPU}"
            memory: "${RESOURCE_REQUESTS_MEMORY}"
          limits:
            cpu: "${RESOURCE_LIMITS_CPU}"
            memory: "${RESOURCE_LIMITS_MEMORY}"
        ports:
        - containerPort: ${TARGET_SERVICE_PORT:-8080}
        readinessProbe:
          tcpSocket:
            port: ${TARGET_SERVICE_PORT:-8080}
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          tcpSocket:
            port: ${TARGET_SERVICE_PORT:-8080}
          initialDelaySeconds: 30
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: autoopt-${TARGET}
spec:
  selector:
    app: autoopt-${TARGET}
  ports:
  - port: ${TARGET_SERVICE_PORT:-8080}
    targetPort: ${TARGET_SERVICE_PORT:-8080}
```

Variables are substituted by `envsubst` in deploy.sh.

---

## 9. Branch Strategy

### 9.1 Branch Naming

```
autoopt/<target>/<tag>-baseline     # initial unmodified run
autoopt/<target>/<tag>-exp001       # first experiment
autoopt/<target>/<tag>-exp002       # second experiment
...
autoopt/<target>/<tag>-exp<NNN>     # zero-padded 3-digit number
```

- `<target>` = target name (clickhouse, kafka, etc.)
- `<tag>` = human-provided identifier, typically date-based (mar22, mar22a, q1-memory)
- Branches live in `targets/<target>/src/.git` (the target's git repo), NOT the framework repo

### 9.2 Branch Lifecycle

```
baseline ──→ exp001 (keep) ──→ exp003 (keep) ──→ exp007 (keep) ──→ exp012 (keep)  ← frontier
               │                  │
               └→ exp002 (discard) └→ exp004 (crash)
                                   └→ exp005 (discard)
                                   └→ exp006 (constraint_violation)
```

- **Frontier** = the latest "keep" branch; all new experiments fork from here
- **Discard/crash branches** = kept for history, never used as base
- **Resume** = checkout the frontier, compute next exp number from results.tsv

### 9.3 Structured Commit Messages

```
[autoopt] exp003: reduce MergeTree allocator block size

Target: clickhouse
Environment: local
Metric: peak_rss_mb
Baseline: 4200.3
Parent: 4100.2 (exp001)
Result: 3850.1
Delta vs baseline: -8.3%
Delta vs parent: -6.1%
Status: keep

Files changed:
  src/Storages/MergeTree/MergeTreeDataPartWriterOnDisk.cpp
  src/Storages/MergeTree/MergeTreeSettings.h
```

---

## 10. Source Code Management

### 10.1 Two-Repo Model

| Aspect | Framework Repo | Target Source |
|--------|---------------|---------------|
| Location | `autooptimization/` (root) | `targets/<name>/src/` |
| Git | framework's `.git` | target's own `.git` |
| Tracked by framework | Yes | No (`.gitignore`'d) |
| Branches | `main` only | `autoopt/*` experiment branches |
| Agent edits | Never | Yes (editable scope only) |

### 10.2 .gitignore

See section 5.1 for the canonical `.gitignore` content.

---

## 11. Observability

### 11.1 status.json — Agent Heartbeat

Written by the agent after every step change. Human or monitoring can poll this file.

```json
{
  "target": "clickhouse",
  "environment": "local",
  "tag": "mar22",
  "state": "workload",
  "current_experiment": "exp003",
  "current_branch": "autoopt/clickhouse/mar22-exp003",
  "frontier_branch": "autoopt/clickhouse/mar22-exp001",
  "started_at": "2026-03-22T10:00:00Z",
  "last_updated": "2026-03-22T14:35:22Z",
  "experiment_started_at": "2026-03-22T14:30:00Z",
  "total_experiments": 3,
  "kept": 1,
  "discarded": 1,
  "crashed": 0,
  "consecutive_failures": 0,
  "cumulative_improvement_pct": -2.4,
  "baseline_value": 4200.3,
  "best_value": 4100.2,
  "best_experiment": "exp001",
  "primary_metric": "peak_rss_mb",
  "error": null
}
```

**`state` values:** `setup`, `scanning`, `editing`, `building`, `deploying`, `workload`, `collecting`, `validating`, `analyzing`, `recording`, `idle`, `stopped`, `error`

### 11.2 Per-Experiment Log Files

Every experiment produces log files in `results/<target>/<env>/logs/`:

```
exp003-build.log       # docker build output
exp003-deploy.log      # kubectl apply, wait, port-forward output
exp003-workload.log    # workload script output (queries, responses)
exp003-metrics.log     # collected metrics in key=value format
exp003-validate.log    # validation/test results
exp003-teardown.log    # teardown output
```

The agent captures stdout+stderr of each script into the corresponding log file.

### 11.3 results.tsv — Full Experiment History

Tab-separated, append-only (until explicit cleanup). Schema:

```
exp_id          # 001, 002, ... or "baseline"
branch          # full branch name
parent_branch   # parent branch name or "-" for baseline
commit          # short commit hash (7 chars)
metric_name     # primary metric key
metric_value    # observed value
baseline_value  # original baseline value
delta_vs_baseline # percentage change from baseline
delta_vs_parent # percentage change from parent
cpu_pct         # CPU utilization
latency_p99_ms  # p99 latency
error_rate      # error rate during workload
pod_restarts    # number of pod restarts during experiment
status          # keep, discard, crash, invalid, constraint_violation, timeout
description     # 1-line description of what was tried
```

### 11.4 summary.md — Human-Readable Dashboard

Regenerated after every experiment. Contains:
- Best result and current frontier
- Full experiment timeline table
- Frontier lineage (chain of "keep" experiments)
- What worked / what didn't work
- Constraint status
- Total stats (kept, discarded, crashed)

### 11.5 Monitoring the Agent

The human can check progress at any time:

```bash
# Quick status
cat results/clickhouse/local/status.json | jq '.state, .total_experiments, .cumulative_improvement_pct'

# Full summary
cat results/clickhouse/local/summary.md

# List all experiment branches
cd targets/clickhouse/src && git branch --list 'autoopt/clickhouse/mar22-*'

# See what the last experiment tried
cd targets/clickhouse/src && git log --oneline -1

# See the diff of a specific experiment
cd targets/clickhouse/src && git diff autoopt/clickhouse/mar22-exp002..autoopt/clickhouse/mar22-exp003

# Watch the raw results
cat results/clickhouse/local/results.tsv | column -t -s$'\t'
```

---

## 12. Environment Overlay System

### 12.1 Architecture

```
envs/
├── base/           ← defaults for everything
│   ├── env.conf
│   ├── build.sh
│   ├── deploy.sh
│   ├── workload.sh
│   ├── collect.sh
│   ├── validate.sh
│   ├── teardown.sh
│   └── cleanup.sh
├── local/          ← overrides for local kind cluster
│   ├── env.conf
│   └── build.sh    ← only overrides build (kind load)
├── staging/
│   ├── env.conf
│   └── collect.sh  ← only overrides collection (prometheus)
├── prod/
│   ├── env.conf    ← SAFETY_LEVEL=approval_required
│   └── collect.sh  ← only overrides collection (datadog)
└── prod-eu/
    ├── env.conf
    └── deploy.sh   ← only overrides deploy (EU node affinity)
```

### 12.2 Resolution Order

```
1. Source envs/base/env.conf (defaults)
2. Source envs/<env>/env.conf (overrides, if exists)
3. Look for envs/<env>/<script> (override script)
4. If not found, fall back to envs/base/<script>
5. Execute the resolved script with all env vars exported
```

### 12.3 Environment Variables — Full Reference

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `KUBECONFIG` | path | `~/.kube/config` | Path to kubeconfig |
| `KUBE_CONTEXT` | string | `kind-autoopt` | K8s context to use |
| `NAMESPACE` | string | `autoopt` | K8s namespace for experiments |
| `REGISTRY` | string | `local` | Container registry (`local` = kind load) |
| `IMAGE_TAG` | string | `latest` | Docker image tag |
| `RESOURCE_LIMITS_CPU` | int | `2` | CPU limit for pod (cores) |
| `RESOURCE_LIMITS_MEMORY` | string | `8Gi` | Memory limit for pod |
| `RESOURCE_REQUESTS_CPU` | int | `1` | CPU request for pod |
| `RESOURCE_REQUESTS_MEMORY` | string | `4Gi` | Memory request for pod |
| `BUILD_TIMEOUT` | int | `600` | Build timeout (seconds) |
| `DEPLOY_TIMEOUT` | int | `300` | Deploy wait timeout (seconds) |
| `WORKLOAD_TIMEOUT` | int | `600` | Workload timeout (seconds) |
| `COLLECT_TIMEOUT` | int | `60` | Metric collection timeout |
| `EXPERIMENT_TIMEOUT` | int | `1800` | Total experiment timeout (30 min) |
| `COLLECT_METHOD` | string | `kubectl` | Metric source: kubectl, prometheus, datadog |
| `COLLECT_INTERVAL` | int | `5` | Seconds between metric samples |
| `WARMUP_SECONDS` | int | `30` | Wait after deploy before workload |
| `WORKLOAD_RUNS` | int | `3` | Run workload N times, take median |
| `MIN_IMPROVEMENT_PCT` | float | `1` | Below this = noise, discard |
| `SAFETY_LEVEL` | string | `autonomous` | autonomous or approval_required |
| `MAX_CONSECUTIVE_FAILURES` | int | `3` | Stop after N consecutive failures |
| `MAX_REGRESSION_PCT` | int | `50` | Stop if any metric regresses > N% |
| `TARGET_SERVICE_PORT` | int | `8080` | Port the target service listens on |
| `PROMETHEUS_URL` | string | - | Prometheus endpoint (staging) |
| `DD_API_KEY` | string | - | Datadog API key (prod) |

---

## 13. Safety & Environment Protection

### 13.1 Safety Levels

| Level | Behavior | Use for |
|-------|----------|---------|
| `autonomous` | Agent runs freely, no human approval needed | local, staging |
| `approval_required` | Agent pauses before deploy, shows diff, waits for human | prod |

### 13.2 Termination Conditions

The agent stops the loop and reports to the human when:

| Condition | Trigger | Agent action |
|-----------|---------|--------------|
| Consecutive failures | `consecutive_failures >= MAX_CONSECUTIVE_FAILURES` | Stop, report "stuck after N failures" |
| Severe regression | Any metric regresses > `MAX_REGRESSION_PCT` from baseline | Stop, report "severe regression detected" |
| Experiment timeout | Single experiment exceeds `EXPERIMENT_TIMEOUT` | Kill, teardown, mark as timeout, continue |
| Human interrupt | Human stops the agent process | Agent writes final status.json |
| No ideas left | Agent cannot think of new optimizations | Report, ask human for guidance |

### 13.3 Idempotency

All scripts MUST be idempotent (safe to run twice):
- `deploy.sh` uses `kubectl apply` (not `create`)
- `teardown.sh` uses `--ignore-not-found`
- `build.sh` overwrites existing image tags
- `results.tsv` is append-only (no in-place edits)

### 13.4 Resource Isolation

- Each target+environment gets its own K8s namespace
- Naming convention: `autoopt` (local), `autoopt-staging`, `autoopt-prod`
- Resource limits are set via env.conf per environment
- One agent instance per target+environment (no concurrent experiments on same target+env)

---

## 14. Metric Collection — Language-Agnostic

### 14.1 Core Metrics (always available)

| Metric | Source | How | Works for |
|--------|--------|-----|-----------|
| `peak_rss_mb` | `/proc/1/status` VmHWM | `kubectl exec -- cat /proc/1/status` | Any language |
| `current_rss_mb` | `/proc/1/status` VmRSS | `kubectl exec -- cat /proc/1/status` | Any language |
| `cpu_pct` | `kubectl top pod` | millicores / limit * 100 | Any language |
| `pod_restarts` | pod status | `kubectl get pod -o jsonpath` | Any language |

### 14.2 Workload Metrics (from target's workload.sh)

| Metric | Produced by | Description |
|--------|-------------|-------------|
| `latency_p99_ms` | workload.sh | 99th percentile response latency |
| `latency_p50_ms` | workload.sh | 50th percentile response latency |
| `throughput_qps` | workload.sh | Queries/requests per second |
| `error_rate` | workload.sh | Fraction of failed requests |
| `total_requests` | workload.sh | Total requests in workload run |

### 14.3 Optional Metrics (perf, if available)

| Metric | Source | When available |
|--------|--------|----------------|
| `cpu_cycles` | `perf stat` | Linux with perf_event access |
| `cache_misses` | `perf stat` | Linux with perf_event access |
| `instructions` | `perf stat` | Linux with perf_event access |
| `ipc` | `perf stat` | Linux with perf_event access |

These require the pod to have `SYS_ADMIN` capability or `perf_event_paranoid` set. Available as opt-in via target config.

### 14.4 Language-Specific Profilers (optional plugins)

Not required by the framework, but targets can include them:

| Language | Tool | Integration |
|----------|------|-------------|
| Java | async-profiler | Mount agent JAR, collect flame graph |
| C++ | perf record | Collect perf.data, generate flame graph |
| Python | py-spy | Attach to PID, collect profile |
| Go | pprof | HTTP endpoint at /debug/pprof |

These are implemented in the target's `workload.sh` or a separate `profile.sh` — not in the framework.

### 14.5 Statistical Stability

To handle metric noise:
- Workload runs `WORKLOAD_RUNS` times (default: 3)
- `collect.sh` takes the **median** of workload metrics across runs
- `MIN_IMPROVEMENT_PCT` (default: 1%) filters out noise — changes below this threshold are discarded
- Container-level metrics (peak RSS, CPU) are read once after the final workload run (they accumulate)

---

## 15. Non-Functional Requirements

### 15.1 Reliability

| Requirement | How |
|-------------|-----|
| Agent crash recovery | All state in git + results.tsv; resume protocol in §4.4 |
| Script crash recovery | Each script is independently re-runnable (idempotent) |
| K8s pod crash during experiment | Detected by validate.sh (restart count), marked as crash |
| Network interruption | Scripts use kubectl with timeouts; agent retries failed commands |
| Disk full | Agent checks disk space before build; build.sh prunes old images |

### 15.2 Performance

| Aspect | Target |
|--------|--------|
| Experiment cycle time | Depends on target (build time + workload duration) |
| Build time (ClickHouse) | ~5-10 min (incremental Docker builds via layer caching) |
| Deploy time | ~30s (image pull + pod startup) |
| Workload time | Configurable per target (default: 2 min) |
| Metric collection | ~5s |
| Overhead per experiment | ~2 min (git operations, analysis, summary generation) |
| Expected experiments/hour | ~3-4 for large C++ projects, ~6-10 for smaller Java projects |

### 15.3 Scalability

| Dimension | Supported | How |
|-----------|-----------|-----|
| Multiple targets | Yes | Each target = separate directory |
| Multiple environments | Yes | Each env = separate overlay |
| Parallel targets | Yes | Different agents on different targets (separate namespaces) |
| Parallel envs for same target | Yes | Different agents, different env (results tracked separately) |
| Parallel experiments on same target+env | No | One agent at a time per target+env |
| Large codebases | Yes | Git clone with --depth 1; agent reads only editable scope |

### 15.4 Maintainability

| Aspect | How |
|--------|-----|
| Adding a new target | Create `targets/<name>/` with 5 files. No framework changes. |
| Adding a new environment | Create `envs/<name>/` with env.conf + any overrides. No framework changes. |
| Adding a new metric | Add to collect.sh output; agent will pick it up from metrics.log |
| Changing the loop | Edit program.md. Agent follows new instructions next run. |
| Updating framework scripts | Edit envs/base/*.sh. All environments inherit changes unless overridden. |

---

## 16. Quality & Correctness

### 16.1 Validation Pipeline

Every experiment passes through multiple quality gates:

```
Build succeeds?
  └─ No → crash/discard
  └─ Yes ↓
Deploy succeeds? Pod is ready?
  └─ No → crash/discard
  └─ Yes ↓
Workload completes without errors?
  └─ No → crash/discard
  └─ Yes ↓
validate.sh passes? (target-specific tests + pod stability)
  └─ No → invalid/discard
  └─ Yes ↓
Constraints met? (latency, error rate, etc.)
  └─ No → constraint_violation/discard
  └─ Yes ↓
Primary metric improved above noise threshold?
  └─ No → discard
  └─ Yes → KEEP
```

### 16.2 What validate.sh Can Check

| Check | Description | When |
|-------|-------------|------|
| Pod stability | No restarts during experiment | Always |
| Pod health | Pod still Running after workload | Always |
| Target test suite | Run subset of unit tests | If target provides validate.sh |
| Functional correctness | Query results match expected output | If target provides validate.sh |
| No data corruption | Checksum of output data | If target provides validate.sh |

### 16.3 Framework Self-Tests

Before running experiments, the agent verifies:

```bash
# Tools available
which docker kubectl git bc timeout envsubst

# K8s cluster reachable
kubectl --context "$KUBE_CONTEXT" cluster-info

# Docker daemon running
docker info > /dev/null

# Target directory exists and has required files
[ -f "targets/$TARGET/target.md" ]
[ -f "targets/$TARGET/Dockerfile" ]
[ -f "targets/$TARGET/k8s.yaml" ]
[ -f "targets/$TARGET/workload.sh" ]

# Results directory writable
mkdir -p "results/$TARGET/$ENV/logs"
touch "results/$TARGET/$ENV/.write-test" && rm "results/$TARGET/$ENV/.write-test"

# Target source cloned
[ -d "targets/$TARGET/src/.git" ]
```

---

## 17. Adding a New Target — Checklist

To optimize a new project:

```
1. Create directory: mkdir -p targets/<name>

2. Write target.md:
   - Source repo URL and branch
   - Primary metric name, direction, unit
   - Secondary metrics
   - Workload description and timing
   - Editable and readonly file scopes
   - Constraints

3. Write Dockerfile:
   - Multi-stage build recommended
   - Final image should run the target server
   - Expose the service port

4. Write k8s.yaml:
   - Deployment with ${IMAGE_NAME}, resource vars from envsubst
   - Service exposing the target port
   - Readiness and liveness probes

5. Write workload.sh:
   - Must accept SERVICE_HOST, SERVICE_PORT env vars
   - Must output latency_p99_ms=, throughput_qps=, error_rate= to stdout
   - Must exit 0 on success, 1 on failure

6. (Optional) Write hints.md:
   - Known hot spots
   - Past optimization attempts
   - Areas to avoid

7. (Optional) Write validate.sh:
   - Target-specific correctness checks
   - Subset of unit tests that run fast

8. Clone source:
   git clone --branch <branch> --depth 1 <repo_url> targets/<name>/src

9. Test manually:
   ./run.sh local build.sh <name>
   ./run.sh local deploy.sh <name>
   ./run.sh local workload.sh <name>
   ./run.sh local collect.sh <name>
   ./run.sh local teardown.sh <name>

10. Start the agent:
    "Read program.md. Target: <name>. Environment: local.
     Primary metric: <metric>. Tag: <tag>. Go."
```

---

## 18. End-to-End Example

```
Human: "Optimize ClickHouse memory usage. Focus on MergeTree storage."

=== SETUP ===

Agent reads program.md → understands the loop
Agent reads targets/clickhouse/target.md → metric=peak_rss_mb, direction=lower
Agent reads targets/clickhouse/hints.md → "MergeTree allocates heavily during merges"
Agent verifies environment:
  $ kubectl --context kind-autoopt cluster-info    → ✓ cluster running
  $ docker info                                     → ✓ daemon running
  $ ls targets/clickhouse/src/.git                  → ✓ source cloned

Agent initializes:
  $ mkdir -p results/clickhouse/local/logs
  $ echo -e "exp_id\tbranch\t..." > results/clickhouse/local/results.tsv

=== BASELINE ===

Agent:
  $ cd targets/clickhouse/src
  $ git checkout -b autoopt/clickhouse/mar22-baseline
  $ cd ../../..
  $ ./run.sh local build.sh clickhouse    > results/clickhouse/local/logs/baseline-build.log 2>&1
    → [build] Building autoopt-clickhouse:latest... Done.
  $ ./run.sh local deploy.sh clickhouse   > results/clickhouse/local/logs/baseline-deploy.log 2>&1
    → [deploy] Pod ready. Service at localhost:31234
  $ ./run.sh local workload.sh clickhouse > results/clickhouse/local/logs/baseline-workload.log 2>&1
    → [workload] 3 runs completed.
  $ ./run.sh local collect.sh clickhouse  > results/clickhouse/local/logs/baseline-metrics.log
    → peak_rss_mb=4200.3, cpu_pct=72.1, latency_p99_ms=45.3
  $ ./run.sh local validate.sh clickhouse > results/clickhouse/local/logs/baseline-validate.log 2>&1
    → [validate] PASSED
  $ ./run.sh local teardown.sh clickhouse

Agent records baseline in results.tsv.
Agent writes status.json: {"state":"idle","baseline_value":4200.3}

=== EXPERIMENT LOOP ===

--- Experiment 001 ---

Agent scans src/Storages/MergeTree/
Agent idea: "Pool allocator for small MergeTree objects to reduce malloc overhead"

  $ cd targets/clickhouse/src
  $ git checkout autoopt/clickhouse/mar22-baseline
  $ git checkout -b autoopt/clickhouse/mar22-exp001
  # Agent edits MergeTreeDataPartWriterOnDisk.cpp, adds pool allocator
  $ git add -A && git commit -m "[autoopt] exp001: pool allocator for small objects"
  $ cd ../../..

Agent writes status.json: {"state":"building","current_experiment":"exp001"}
  $ ./run.sh local build.sh clickhouse  > results/clickhouse/local/logs/exp001-build.log 2>&1   → exit 0 ✓

Agent writes status.json: {"state":"deploying"}
  $ ./run.sh local deploy.sh clickhouse > results/clickhouse/local/logs/exp001-deploy.log 2>&1  → exit 0 ✓

Agent writes status.json: {"state":"workload"}
  $ ./run.sh local workload.sh clickhouse > results/clickhouse/local/logs/exp001-workload.log 2>&1 → exit 0 ✓

Agent writes status.json: {"state":"collecting"}
  $ ./run.sh local collect.sh clickhouse > results/clickhouse/local/logs/exp001-metrics.log
    → peak_rss_mb=4100.2, cpu_pct=72.1, latency_p99_ms=44.8

Agent writes status.json: {"state":"validating"}
  $ ./run.sh local validate.sh clickhouse > results/clickhouse/local/logs/exp001-validate.log 2>&1 → PASSED ✓

Agent writes status.json: {"state":"analyzing"}
Agent analyzes:
  primary metric:    4100.2 (was 4200.3 baseline)
  delta_vs_baseline: -2.4%
  delta_vs_parent:   -2.4% (parent = baseline)
  above noise (1%):  YES
  constraints:       latency 44.8ms < 49.8ms (10% of 45.3) → PASS
  decision:          KEEP ✓

Agent records exp001 in results.tsv.
  $ ./run.sh local teardown.sh clickhouse
Agent updates summary.md.
Agent writes status.json: {"state":"idle","frontier_branch":"...exp001","cumulative_improvement_pct":-2.4}

--- Experiment 002 ---

Agent idea: "Use mmap instead of malloc for large block allocations"
  $ git checkout autoopt/clickhouse/mar22-exp001  # fork from last keep
  $ git checkout -b autoopt/clickhouse/mar22-exp002
  # Agent edits Allocator.h
  $ git commit ...

  Build → Deploy → Workload → Collect → Validate
  → peak_rss_mb=4250.0 (WORSE: +1.2%)
  → decision: DISCARD

Agent records exp002 in results.tsv (status=discard).
Teardown. Update summary.
Frontier unchanged: still exp001.

--- Experiment 003 ---

Agent idea: "Reduce MergeTree allocator block size from 64KB to 16KB"
  $ git checkout autoopt/clickhouse/mar22-exp001  # still fork from exp001 (last keep)
  $ git checkout -b autoopt/clickhouse/mar22-exp003
  # Agent edits MergeTreeSettings.h
  $ git commit ...

  Build → Deploy → Workload → Collect → Validate
  → peak_rss_mb=3850.1 (BETTER: -8.3% vs baseline, -6.1% vs parent)
  → latency_p99_ms=46.0 (within 10% constraint ✓)
  → decision: KEEP ✓

Agent records exp003 in results.tsv.
Frontier advances to exp003.
Summary updated: "Best: exp003, -8.3% from baseline"

... continues forever ...

=== HUMAN CHECKS PROGRESS ===

  $ cat results/clickhouse/local/status.json | jq .
  $ cat results/clickhouse/local/summary.md
  $ cat results/clickhouse/local/results.tsv | column -t -s$'\t'
  $ cd targets/clickhouse/src && git log --oneline autoopt/clickhouse/mar22-exp003
  $ cd targets/clickhouse/src && git diff autoopt/clickhouse/mar22-exp001..autoopt/clickhouse/mar22-exp003
```
