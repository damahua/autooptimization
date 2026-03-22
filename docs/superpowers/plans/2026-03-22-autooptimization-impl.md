# Auto-Optimization Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a shell-script-based framework that lets an AI agent autonomously optimize code by iterating: scan code, modify, build Docker image, deploy to K8s, run workload, collect metrics, keep/discard, repeat.

**Architecture:** Shell scripts called by an AI agent via `run.sh` dispatcher. Environment overlays (base/local/staging/prod) handle different K8s clusters. Target projects are pluggable directories with Dockerfile, k8s.yaml, workload.sh, and config files. All state lives in git branches + results.tsv.

**Tech Stack:** Bash, Docker, Kubernetes (kind for local), kubectl, envsubst, git

**Spec:** `docs/superpowers/specs/2026-03-22-autooptimization-design.md`

**Scope:** This plan implements the core framework with `base/` and `local/` environments only. Staging/prod/prod-eu environments and `status.json` observability are deferred to a follow-up plan.

---

## File Map

```
autooptimization/
├── .gitignore                          # Task 1
├── run.sh                              # Task 2
├── program.md                          # Task 8
├── envs/
│   ├── base/
│   │   ├── env.conf                    # Task 3
│   │   ├── build.sh                    # Task 4
│   │   ├── deploy.sh                   # Task 4
│   │   ├── workload.sh                 # Task 4
│   │   ├── collect.sh                  # Task 5
│   │   ├── validate.sh                 # Task 5
│   │   ├── teardown.sh                 # Task 4
│   │   └── cleanup.sh                  # Task 6
│   └── local/
│       ├── env.conf                    # Task 3
│       └── build.sh                    # Task 4
├── targets/
│   └── clickhouse/
│       ├── target.md                   # Task 7
│       ├── hints.md                    # Task 7
│       ├── Dockerfile                  # Task 7
│       ├── k8s.yaml                    # Task 7
│       └── workload.sh                 # Task 7
└── results/                            # created at runtime
```

---

### Task 1: Project Scaffolding

**Files:**
- Create: `.gitignore`
- Create: directory structure (`envs/base/`, `envs/local/`, `targets/`, `results/`)

- [ ] **Step 1: Initialize git repo**

```bash
cd /Users/lezhang/Work/autooptimization
git init
```

- [ ] **Step 2: Create directory structure**

```bash
mkdir -p envs/base envs/local targets results
```

- [ ] **Step 3: Create .gitignore**

Write `.gitignore`:

```
# Target source code (each is its own git repo)
targets/*/src/

# Experiment results (generated)
results/

# Runtime artifacts
*.log
/tmp/autoopt-*
```

- [ ] **Step 4: Verify structure**

```bash
find . -type d | grep -v '.git/' | sort
```

Expected:
```
.
./docs
./envs
./envs/base
./envs/local
./results
./targets
```

- [ ] **Step 5: Commit**

```bash
git add .gitignore
git commit -m "chore: initialize project scaffolding with .gitignore"
```

---

### Task 2: run.sh Dispatcher

**Files:**
- Create: `run.sh`

- [ ] **Step 1: Create a minimal env.conf for testing**

Write `envs/base/env.conf`:

```bash
# Placeholder for testing run.sh
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-autoopt}"
```

- [ ] **Step 2: Create a test script to verify dispatching**

Write `envs/base/test-dispatch.sh`:

```bash
#!/bin/bash
echo "[test-dispatch] TARGET=$TARGET ENV=$ENV FRAMEWORK_ROOT=$FRAMEWORK_ROOT KUBE_CONTEXT=$KUBE_CONTEXT"
exit 0
```

```bash
chmod +x envs/base/test-dispatch.sh
```

- [ ] **Step 3: Write run.sh**

Write `run.sh`:

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

```bash
chmod +x run.sh
```

- [ ] **Step 4: Test run.sh dispatching — base fallback**

```bash
mkdir -p targets/test-target
./run.sh local test-dispatch.sh test-target
```

Expected output:
```
[test-dispatch] TARGET=test-target ENV=local FRAMEWORK_ROOT=/Users/lezhang/Work/autooptimization KUBE_CONTEXT=kind-autoopt
```

- [ ] **Step 5: Test run.sh — env-specific override**

Write `envs/local/test-dispatch.sh`:

```bash
#!/bin/bash
echo "[test-dispatch-local] TARGET=$TARGET ENV=$ENV KUBE_CONTEXT=$KUBE_CONTEXT"
exit 0
```

```bash
chmod +x envs/local/test-dispatch.sh
```

```bash
./run.sh local test-dispatch.sh test-target
```

Expected output:
```
[test-dispatch-local] TARGET=test-target ENV=local KUBE_CONTEXT=kind-autoopt
```

- [ ] **Step 6: Test run.sh — error cases**

```bash
# Missing env
./run.sh nonexistent test-dispatch.sh test-target 2>&1 | grep "ERROR"
# Expected: [run.sh] ERROR: Environment 'nonexistent' not found in envs/

# Missing script
./run.sh local nonexistent.sh test-target 2>&1 | grep "ERROR"
# Expected: [run.sh] ERROR: Script 'nonexistent.sh' not found
```

- [ ] **Step 7: Clean up test fixtures and commit**

```bash
rm -f envs/base/test-dispatch.sh envs/local/test-dispatch.sh
rm -rf targets/test-target
git add run.sh envs/base/env.conf
git commit -m "feat: add run.sh dispatcher with env overlay resolution"
```

---

### Task 3: Environment Configuration

**Files:**
- Create: `envs/base/env.conf`
- Create: `envs/local/env.conf`

- [ ] **Step 1: Write base/env.conf with all defaults**

Write `envs/base/env.conf`:

```bash
# === Kubernetes ===
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-autoopt}"
NAMESPACE="${NAMESPACE:-autoopt}"

# === Container Registry ===
REGISTRY="${REGISTRY:-local}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# === Resource Limits (for K8s pod) ===
RESOURCE_LIMITS_CPU="${RESOURCE_LIMITS_CPU:-2}"
RESOURCE_LIMITS_MEMORY="${RESOURCE_LIMITS_MEMORY:-8Gi}"
RESOURCE_REQUESTS_CPU="${RESOURCE_REQUESTS_CPU:-1}"
RESOURCE_REQUESTS_MEMORY="${RESOURCE_REQUESTS_MEMORY:-4Gi}"

# === Timeouts (seconds) ===
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-300}"
WORKLOAD_TIMEOUT="${WORKLOAD_TIMEOUT:-600}"
COLLECT_TIMEOUT="${COLLECT_TIMEOUT:-60}"
EXPERIMENT_TIMEOUT="${EXPERIMENT_TIMEOUT:-1800}"

# === Metric Collection ===
COLLECT_METHOD="${COLLECT_METHOD:-kubectl}"
COLLECT_INTERVAL="${COLLECT_INTERVAL:-5}"

# === Safety ===
SAFETY_LEVEL="${SAFETY_LEVEL:-autonomous}"
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"
MAX_REGRESSION_PCT="${MAX_REGRESSION_PCT:-50}"

# === Workload ===
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
WORKLOAD_RUNS="${WORKLOAD_RUNS:-3}"
MIN_IMPROVEMENT_PCT="${MIN_IMPROVEMENT_PCT:-1}"

# === Target Service ===
TARGET_SERVICE_PORT="${TARGET_SERVICE_PORT:-8080}"
```

- [ ] **Step 2: Write local/env.conf**

Write `envs/local/env.conf`:

```bash
# Local environment: kind cluster
KUBE_CONTEXT="kind-autoopt"
NAMESPACE="autoopt"
REGISTRY="local"
SAFETY_LEVEL="autonomous"

# Smaller timeouts for local dev
BUILD_TIMEOUT=600
DEPLOY_TIMEOUT=120
WORKLOAD_TIMEOUT=300
```

- [ ] **Step 3: Verify env.conf sourcing order**

```bash
# Source base, then local, and check that local overrides win
(
  source envs/base/env.conf
  echo "base DEPLOY_TIMEOUT=$DEPLOY_TIMEOUT"
  source envs/local/env.conf
  echo "local DEPLOY_TIMEOUT=$DEPLOY_TIMEOUT"
)
```

Expected:
```
base DEPLOY_TIMEOUT=300
local DEPLOY_TIMEOUT=120
```

- [ ] **Step 4: Commit**

```bash
git add envs/base/env.conf envs/local/env.conf
git commit -m "feat: add base and local environment configurations"
```

---

### Task 4: Core Scripts (build, deploy, workload, teardown)

**Files:**
- Create: `envs/base/build.sh`
- Create: `envs/base/deploy.sh`
- Create: `envs/base/workload.sh`
- Create: `envs/base/teardown.sh`
- Create: `envs/local/build.sh`

- [ ] **Step 1: Write base/build.sh**

Write `envs/base/build.sh`:

```bash
#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

echo "[build] Building autoopt-$TARGET:$IMAGE_TAG"
echo "[build] Dockerfile: $TARGET_DIR/Dockerfile"
echo "[build] Context: $TARGET_DIR/src"

# Build image with timeout
timeout "$BUILD_TIMEOUT" docker build \
  -t "autoopt-$TARGET:$IMAGE_TAG" \
  -f "$TARGET_DIR/Dockerfile" \
  "$TARGET_DIR/src"

# Push to remote registry
if [ "$REGISTRY" != "local" ]; then
  docker tag "autoopt-$TARGET:$IMAGE_TAG" "$REGISTRY/autoopt-$TARGET:$IMAGE_TAG"
  docker push "$REGISTRY/autoopt-$TARGET:$IMAGE_TAG"
fi

echo "[build] Done. Image: autoopt-$TARGET:$IMAGE_TAG"
```

```bash
chmod +x envs/base/build.sh
```

- [ ] **Step 2: Write local/build.sh (kind override)**

Write `envs/local/build.sh`:

```bash
#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

echo "[build] Building autoopt-$TARGET:$IMAGE_TAG (local/kind)"
echo "[build] Dockerfile: $TARGET_DIR/Dockerfile"
echo "[build] Context: $TARGET_DIR/src"

# Build image with timeout
timeout "$BUILD_TIMEOUT" docker build \
  -t "autoopt-$TARGET:$IMAGE_TAG" \
  -f "$TARGET_DIR/Dockerfile" \
  "$TARGET_DIR/src"

# Load into kind cluster
echo "[build] Loading image into kind cluster..."
kind load docker-image "autoopt-$TARGET:$IMAGE_TAG" --name autoopt 2>/dev/null || \
  echo "[build] WARNING: kind load failed (cluster may not exist yet)"

echo "[build] Done. Image: autoopt-$TARGET:$IMAGE_TAG"
```

```bash
chmod +x envs/local/build.sh
```

- [ ] **Step 3: Write base/deploy.sh**

Write `envs/base/deploy.sh`:

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

```bash
chmod +x envs/base/deploy.sh
```

- [ ] **Step 4: Write base/workload.sh**

Write `envs/base/workload.sh`:

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
if ! timeout 30 bash -c "until curl -sf http://\$SERVICE_HOST:\$SERVICE_PORT/health 2>/dev/null || nc -z \$SERVICE_HOST \$SERVICE_PORT 2>/dev/null; do sleep 1; done"; then
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
  set +e
  timeout "$WORKLOAD_TIMEOUT" "$TARGET_DIR/workload.sh" >> "$WORKLOAD_METRICS_FILE" 2>&1
  WORKLOAD_EXIT=$?
  set -e
  if [ $WORKLOAD_EXIT -ne 0 ]; then
    echo "[workload] WARNING: Run $i failed (exit $WORKLOAD_EXIT)"
  fi
done

echo "[workload] Done. Raw results in $WORKLOAD_METRICS_FILE"
```

```bash
chmod +x envs/base/workload.sh
```

- [ ] **Step 5: Write base/teardown.sh**

Write `envs/base/teardown.sh`:

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
  delete -f "$TARGET_DIR/k8s.yaml" --ignore-not-found --timeout=60s 2>/dev/null || true

# 3. Wait for pod termination
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  wait --for=delete pod -l "app=autoopt-$TARGET" --timeout=60s 2>/dev/null || true

# 4. Clean up connection env file
rm -f "/tmp/autoopt-$TARGET-connection.env"

echo "[teardown] Done."
```

```bash
chmod +x envs/base/teardown.sh
```

- [ ] **Step 6: Verify all scripts are executable and have correct shebang**

```bash
for f in envs/base/build.sh envs/base/deploy.sh envs/base/workload.sh envs/base/teardown.sh envs/local/build.sh; do
  echo "--- $f ---"
  head -1 "$f"
  ls -la "$f" | awk '{print $1}'
done
```

Expected: each file starts with `#!/bin/bash` and has `-rwxr-xr-x` permissions.

- [ ] **Step 7: Commit**

```bash
git add envs/base/build.sh envs/base/deploy.sh envs/base/workload.sh envs/base/teardown.sh envs/local/build.sh
git commit -m "feat: add core scripts — build, deploy, workload, teardown"
```

---

### Task 5: Metric Collection & Validation Scripts

**Files:**
- Create: `envs/base/collect.sh`
- Create: `envs/base/validate.sh`

- [ ] **Step 1: Write base/collect.sh**

Write `envs/base/collect.sh`:

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
  exec "$POD" -- cat /proc/1/status 2>/dev/null | grep VmHWM | awk '{print $2}' || echo 0)
PEAK_RSS_MB=$(echo "scale=1; ${VM_HWM_KB:-0} / 1024" | bc)

# 2. Current RSS
VM_RSS_KB=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  exec "$POD" -- cat /proc/1/status 2>/dev/null | grep VmRSS | awk '{print $2}' || echo 0)
CURRENT_RSS_MB=$(echo "scale=1; ${VM_RSS_KB:-0} / 1024" | bc)

# 3. CPU from kubectl top
CPU_RAW=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  top pod "$POD" --no-headers 2>/dev/null | awk '{print $2}' || echo "0m")
CPU_MILLICORES="${CPU_RAW%m}"
CPU_LIMIT_MILLICORES=$((RESOURCE_LIMITS_CPU * 1000))
CPU_PCT=$(echo "scale=1; ${CPU_MILLICORES:-0} * 100 / $CPU_LIMIT_MILLICORES" | bc)

# 4. Pod restart count
RESTART_COUNT=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)

# === Workload metrics (from workload.sh output) ===
WORKLOAD_LOG="$RESULTS_DIR/logs/workload-raw.log"
LATENCY_P99=0
THROUGHPUT=0
ERROR_RATE=0
if [ -f "$WORKLOAD_LOG" ]; then
  LATENCY_P99=$(grep "latency_p99_ms=" "$WORKLOAD_LOG" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}' || echo 0)
  THROUGHPUT=$(grep "throughput_qps=" "$WORKLOAD_LOG" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}' || echo 0)
  ERROR_RATE=$(grep "error_rate=" "$WORKLOAD_LOG" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}' || echo 0)
fi

# 5. Memory from kubectl top (cross-check)
MEM_RAW=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  top pod "$POD" --no-headers 2>/dev/null | awk '{print $3}' || echo "unknown")

# === Output in standard format ===
echo "peak_rss_mb=${PEAK_RSS_MB}"
echo "current_rss_mb=${CURRENT_RSS_MB}"
echo "cpu_pct=${CPU_PCT}"
echo "kubectl_mem=${MEM_RAW:-unknown}"
echo "latency_p99_ms=${LATENCY_P99:-0}"
echo "throughput_qps=${THROUGHPUT:-0}"
echo "error_rate=${ERROR_RATE:-0}"
echo "pod_restarts=${RESTART_COUNT}"
```

```bash
chmod +x envs/base/collect.sh
```

- [ ] **Step 2: Write base/validate.sh**

Write `envs/base/validate.sh`:

```bash
#!/bin/bash
set -euo pipefail
TARGET="$1"
TARGET_DIR="$FRAMEWORK_ROOT/targets/$TARGET"

echo "[validate] Running validation for $TARGET..."

# 1. Run target-specific validation if it exists
if [ -f "$TARGET_DIR/validate.sh" ]; then
  echo "[validate] Running target-specific validation..."
  set +e
  "$TARGET_DIR/validate.sh"
  VALIDATE_EXIT=$?
  set -e
  if [ $VALIDATE_EXIT -ne 0 ]; then
    echo "[validate] FAILED: target validation returned $VALIDATE_EXIT"
    exit 1
  fi
fi

# 2. Check pod health after workload
POD=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pod -l "app=autoopt-$TARGET" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$POD" ]; then
  RESTART_COUNT=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)

  if [ "$RESTART_COUNT" -gt 0 ]; then
    echo "[validate] WARNING: Pod restarted $RESTART_COUNT times during experiment"
    echo "[validate] FAILED: pod instability detected"
    exit 1
  fi

  PHASE=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

  if [ "$PHASE" != "Running" ]; then
    echo "[validate] FAILED: pod is in phase $PHASE (expected Running)"
    exit 1
  fi
fi

echo "[validate] PASSED"
```

```bash
chmod +x envs/base/validate.sh
```

- [ ] **Step 3: Verify scripts are executable**

```bash
ls -la envs/base/collect.sh envs/base/validate.sh | awk '{print $1, $NF}'
```

Expected: both have `-rwxr-xr-x`.

- [ ] **Step 4: Commit**

```bash
git add envs/base/collect.sh envs/base/validate.sh
git commit -m "feat: add collect.sh metric collection and validate.sh correctness checks"
```

---

### Task 6: Cleanup Script

**Files:**
- Create: `envs/base/cleanup.sh`

- [ ] **Step 1: Write base/cleanup.sh**

Write `envs/base/cleanup.sh`:

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
  BRANCHES=$(git branch --list "$PATTERN" 2>/dev/null | sed 's/^[* ]*//' || echo "")
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
docker rmi "autoopt-$TARGET:${IMAGE_TAG:-latest}" 2>/dev/null || true

# 4. Optionally remove results
if [ "$CLEAN_ALL" = true ] && [ -d "$RESULTS_DIR" ]; then
  echo "[cleanup] Removing results: $RESULTS_DIR"
  rm -rf "$RESULTS_DIR"
fi

echo "[cleanup] Done."
```

```bash
chmod +x envs/base/cleanup.sh
```

- [ ] **Step 2: Verify script is executable**

```bash
head -1 envs/base/cleanup.sh && ls -la envs/base/cleanup.sh | awk '{print $1}'
```

- [ ] **Step 3: Commit**

```bash
git add envs/base/cleanup.sh
git commit -m "feat: add cleanup.sh for branch and resource cleanup"
```

---

### Task 7: ClickHouse Target Configuration

**Files:**
- Create: `targets/clickhouse/target.md`
- Create: `targets/clickhouse/hints.md`
- Create: `targets/clickhouse/Dockerfile`
- Create: `targets/clickhouse/k8s.yaml`
- Create: `targets/clickhouse/workload.sh`

- [ ] **Step 1: Create target directory**

```bash
mkdir -p targets/clickhouse
```

- [ ] **Step 2: Write target.md**

Write `targets/clickhouse/target.md`:

```markdown
# Target: ClickHouse

## Source
repo: https://github.com/ClickHouse/ClickHouse
branch: master
path: targets/clickhouse/src

## Build
dockerfile: targets/clickhouse/Dockerfile
build_timeout: 600

## Primary Metric
name: peak_rss_mb
direction: lower
unit: MB

## Secondary Metrics
- cpu_pct
- latency_p99_ms
- throughput_qps

## Workload
description: Run analytical queries against single-node ClickHouse
warmup: 30s
duration: 120s
script: targets/clickhouse/workload.sh

## Scope
editable:
  - src/Storages/MergeTree/
  - src/Common/Allocator*
  - src/Interpreters/
  - src/Processors/

readonly:
  - src/Client/
  - tests/

## Constraints
- latency_p99_ms must not increase by more than 10% from baseline
- error_rate must remain 0

## Service
port: 8123
```

- [ ] **Step 3: Write hints.md**

Write `targets/clickhouse/hints.md`:

```markdown
# Optimization Hints: ClickHouse

## Known hot spots
- MergeTree storage engine allocates heavily during merges
- Column decompression buffers are not reused across queries
- The query pipeline creates many small temporary allocations

## Past attempts
- Jemalloc tuning helped in production, may be worth exploring
- LZ4 decompression is CPU-bound, consider streaming decompression

## Don't bother with
- Network layer — not a bottleneck for single-node
- Disk I/O — already optimized with direct I/O

## Architecture notes
- ClickHouse uses a columnar storage format (MergeTree)
- Queries are processed through a pipeline of Processors
- Memory allocations go through Common/Allocator
```

- [ ] **Step 4: Write Dockerfile**

Note: This is a simplified Dockerfile using the official ClickHouse image for initial testing. When the agent actually optimizes ClickHouse source, it will need a build-from-source Dockerfile. For now, this lets us test the full loop.

Write `targets/clickhouse/Dockerfile`:

```dockerfile
# For initial framework testing: use official ClickHouse image
# When optimizing source code, replace with a build-from-source Dockerfile
FROM clickhouse/clickhouse-server:latest

# Expose HTTP and native ports
EXPOSE 8123 9000

# Health check
HEALTHCHECK --interval=5s --timeout=3s \
  CMD wget -qO- http://localhost:8123/ping || exit 1
```

- [ ] **Step 5: Write k8s.yaml**

Write `targets/clickhouse/k8s.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autoopt-clickhouse
  labels:
    app: autoopt-clickhouse
spec:
  replicas: 1
  selector:
    matchLabels:
      app: autoopt-clickhouse
  template:
    metadata:
      labels:
        app: autoopt-clickhouse
    spec:
      containers:
      - name: clickhouse
        image: ${IMAGE_NAME}
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: "${RESOURCE_REQUESTS_CPU}"
            memory: "${RESOURCE_REQUESTS_MEMORY}"
          limits:
            cpu: "${RESOURCE_LIMITS_CPU}"
            memory: "${RESOURCE_LIMITS_MEMORY}"
        ports:
        - containerPort: 8123
          name: http
        - containerPort: 9000
          name: native
        readinessProbe:
          httpGet:
            path: /ping
            port: 8123
          initialDelaySeconds: 5
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /ping
            port: 8123
          initialDelaySeconds: 15
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: autoopt-clickhouse
spec:
  selector:
    app: autoopt-clickhouse
  ports:
  - port: 8123
    targetPort: 8123
    name: http
  - port: 9000
    targetPort: 9000
    name: native
```

- [ ] **Step 6: Write workload.sh**

Write `targets/clickhouse/workload.sh`:

```bash
#!/bin/bash
set -euo pipefail

HOST="${SERVICE_HOST:-localhost}"
PORT="${SERVICE_PORT:-8123}"
BASE_URL="http://$HOST:$PORT"

echo "[clickhouse-workload] Running queries against $BASE_URL"

# Create a test table if it doesn't exist
curl -sf "$BASE_URL" --data-binary "
CREATE TABLE IF NOT EXISTS test_data (
    id UInt64,
    timestamp DateTime,
    value Float64,
    category String
) ENGINE = MergeTree()
ORDER BY (category, timestamp)
" || true

# Insert test data if table is empty
ROW_COUNT=$(curl -sf "$BASE_URL" --data-binary "SELECT count() FROM test_data FORMAT TabSeparated")
if [ "${ROW_COUNT:-0}" -lt 1000 ]; then
  echo "[clickhouse-workload] Inserting test data..."
  curl -sf "$BASE_URL" --data-binary "
  INSERT INTO test_data
  SELECT
      number AS id,
      toDateTime('2024-01-01') + number AS timestamp,
      rand() / 4294967295.0 * 100 AS value,
      arrayElement(['A','B','C','D','E'], (number % 5) + 1) AS category
  FROM numbers(100000)
  "
fi

# Run analytical queries and measure latency
TOTAL_QUERIES=0
FAILED_QUERIES=0
LATENCIES=""

QUERIES=(
  "SELECT category, avg(value), max(value), min(value) FROM test_data GROUP BY category"
  "SELECT toStartOfHour(timestamp) AS hour, count(), avg(value) FROM test_data GROUP BY hour ORDER BY hour"
  "SELECT category, quantile(0.99)(value) FROM test_data GROUP BY category"
  "SELECT * FROM test_data WHERE value > 90 ORDER BY timestamp LIMIT 100"
  "SELECT category, count(), sum(value) FROM test_data WHERE timestamp > '2024-06-01' GROUP BY category"
)

for q in "${QUERIES[@]}"; do
  for run in $(seq 1 5); do
    START_MS=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")
    set +e
    curl -sf "$BASE_URL" --data-binary "$q FORMAT Null" > /dev/null 2>&1
    EXIT_CODE=$?
    set -e
    END_MS=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")

    LATENCY=$((END_MS - START_MS))
    TOTAL_QUERIES=$((TOTAL_QUERIES + 1))

    if [ $EXIT_CODE -ne 0 ]; then
      FAILED_QUERIES=$((FAILED_QUERIES + 1))
    else
      LATENCIES="$LATENCIES $LATENCY"
    fi
  done
done

# Compute metrics
if [ -n "$LATENCIES" ]; then
  SORTED=$(echo "$LATENCIES" | tr ' ' '\n' | sort -n | grep -v '^$')
  COUNT=$(echo "$SORTED" | wc -l | tr -d ' ')
  P99_IDX=$(echo "$COUNT * 99 / 100" | bc)
  P99_IDX=${P99_IDX:-1}
  LATENCY_P99=$(echo "$SORTED" | sed -n "${P99_IDX}p")
  P50_IDX=$(echo "$COUNT / 2" | bc)
  P50_IDX=${P50_IDX:-1}
  LATENCY_P50=$(echo "$SORTED" | sed -n "${P50_IDX}p")
else
  LATENCY_P99=0
  LATENCY_P50=0
fi

DURATION_S=${WORKLOAD_TIMEOUT:-60}
THROUGHPUT=$(echo "scale=1; $TOTAL_QUERIES / ($DURATION_S / $TOTAL_QUERIES)" | bc 2>/dev/null || echo 0)
ERROR_RATE=$(echo "scale=4; $FAILED_QUERIES / $TOTAL_QUERIES" | bc 2>/dev/null || echo 0)

# Output in standard format
echo "latency_p99_ms=${LATENCY_P99:-0}"
echo "latency_p50_ms=${LATENCY_P50:-0}"
echo "throughput_qps=${THROUGHPUT:-0}"
echo "error_rate=${ERROR_RATE}"
echo "total_requests=${TOTAL_QUERIES}"
```

```bash
chmod +x targets/clickhouse/workload.sh
```

- [ ] **Step 7: Verify all target files exist**

```bash
ls -la targets/clickhouse/
```

Expected: target.md, hints.md, Dockerfile, k8s.yaml, workload.sh

- [ ] **Step 8: Commit**

```bash
git add targets/clickhouse/
git commit -m "feat: add ClickHouse target configuration"
```

---

### Task 8: program.md — Agent Instructions

**Files:**
- Create: `program.md`

- [ ] **Step 1: Write program.md**

Write `program.md`:

```markdown
# autooptimization

This is a framework for autonomous AI-driven code optimization. Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).

## Setup

To set up a new optimization run, work with the user to:

1. **Agree on target, environment, metric, and tag:**
   - Target: which project to optimize (e.g., `clickhouse`)
   - Environment: where to deploy (e.g., `local`)
   - Primary metric: what to optimize (e.g., `peak_rss_mb`)
   - Tag: identifier for this run (e.g., `mar22`)

2. **Read the target config:**
   - `targets/<target>/target.md` — repo, metric, scope, constraints
   - `targets/<target>/hints.md` — optimization hints (if exists)

3. **Clone target source** (if not already present):
   ```bash
   REPO_URL=<from target.md>
   BRANCH=<from target.md>
   git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "targets/<target>/src"
   ```

4. **Verify environment:**
   ```bash
   which docker kubectl git
   kubectl --context kind-autoopt cluster-info  # for local env
   docker info
   ```

5. **Initialize results:**
   ```bash
   mkdir -p "results/<target>/<env>/logs"
   echo -e "exp_id\tbranch\tparent_branch\tcommit\tmetric_name\tmetric_value\tbaseline_value\tdelta_vs_baseline\tdelta_vs_parent\tcpu_pct\tlatency_p99_ms\terror_rate\tpod_restarts\tstatus\tdescription" > "results/<target>/<env>/results.tsv"
   ```

6. **Create baseline branch and run baseline:**
   ```bash
   cd targets/<target>/src
   git checkout -b autoopt/<target>/<tag>-baseline
   cd ../../..
   ./run.sh <env> build.sh <target>
   ./run.sh <env> deploy.sh <target>
   ./run.sh <env> workload.sh <target>
   ./run.sh <env> collect.sh <target> > results/<target>/<env>/logs/baseline-metrics.log
   ./run.sh <env> validate.sh <target>
   ./run.sh <env> teardown.sh <target>
   ```

7. **Record baseline** in results.tsv and confirm it looks good.

## Experiment Loop

Once setup is confirmed, run this loop **forever** until the human stops you:

```
1.  Read results.tsv to know what's been tried
2.  Scan target source code in editable scope (from target.md)
3.  Read hints.md if present
4.  Identify an optimization opportunity
5.  Determine parent: last "keep" branch from results.tsv (or baseline)
6.  cd targets/<target>/src
    git checkout <parent_branch>
    git checkout -b autoopt/<target>/<tag>-exp<NNN>
7.  Edit source code to implement the optimization
8.  git add -A && git commit -m "[autoopt] exp<NNN>: <description>"
9.  cd ../../..
10. ./run.sh <env> build.sh <target>    > results/<target>/<env>/logs/exp<NNN>-build.log 2>&1
11. ./run.sh <env> deploy.sh <target>   > results/<target>/<env>/logs/exp<NNN>-deploy.log 2>&1
12. ./run.sh <env> workload.sh <target> > results/<target>/<env>/logs/exp<NNN>-workload.log 2>&1
13. ./run.sh <env> collect.sh <target>  > results/<target>/<env>/logs/exp<NNN>-metrics.log
14. ./run.sh <env> validate.sh <target> > results/<target>/<env>/logs/exp<NNN>-validate.log 2>&1
15. Read primary metric from exp<NNN>-metrics.log
16. Check constraints from target.md
17. Decision:
    - Primary metric improved (above MIN_IMPROVEMENT_PCT) AND constraints pass AND validation pass → KEEP
    - Otherwise → DISCARD
18. Record in results.tsv
19. ./run.sh <env> teardown.sh <target>
20. Update summary.md
21. Repeat from step 1
```

## Rules

- **Only edit files** in editable scope from target.md — never framework scripts
- **Build/deploy crash handling:** try to fix. After 3 consecutive failures on the same experiment, discard it and try a new idea
- **Log everything** to results.tsv regardless of outcome
- **Never stop** — iterate until human interrupts
- **Simpler is better** — same metric with less code is a win
- **One agent per target+env** — do not run concurrent experiments on the same target+environment
- **Safety:** if SAFETY_LEVEL=approval_required (check env.conf), pause after git commit and show the diff before deploying

## Results Format

### results.tsv (tab-separated)

```
exp_id	branch	parent_branch	commit	metric_name	metric_value	baseline_value	delta_vs_baseline	delta_vs_parent	cpu_pct	latency_p99_ms	error_rate	pod_restarts	status	description
```

Status values: `keep`, `discard`, `crash`, `invalid`, `constraint_violation`, `timeout`

### Structured commit messages

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
```

### summary.md

After each experiment, regenerate `results/<target>/<env>/summary.md` with:
- Best result and current frontier branch
- Full experiment timeline table
- Frontier lineage (chain of "keep" experiments)
- What worked / what didn't work
- Constraint status

## Resume Protocol

If you are resuming a previous run:

```bash
# Find last experiment
tail -1 results/<target>/<env>/results.tsv

# Find frontier (last keep)
grep "keep" results/<target>/<env>/results.tsv | tail -1

# Checkout frontier and continue
cd targets/<target>/src
git checkout <frontier_branch>
```

## Metric Direction

Read `direction` from target.md:
- `direction: lower` → smaller values are better (e.g., peak_rss_mb, latency_p99_ms)
- `direction: higher` → larger values are better (e.g., throughput_qps)

The keep/discard decision must account for the direction.
```

- [ ] **Step 2: Verify program.md reads well**

```bash
wc -l program.md
```

Expected: ~130-150 lines.

- [ ] **Step 3: Commit**

```bash
git add program.md
git commit -m "feat: add program.md agent instructions"
```

---

### Task 9: End-to-End Smoke Test (Local Kind)

**Files:**
- No new files; tests the full loop with existing scripts

**Prerequisites:** Docker running, kind installed. If kind cluster doesn't exist, create it.

- [ ] **Step 1: Create kind cluster (if needed)**

```bash
kind get clusters 2>/dev/null | grep -q "autoopt" || kind create cluster --name autoopt
```

Verify:
```bash
kubectl --context kind-autoopt cluster-info
```

- [ ] **Step 2: Build ClickHouse image**

```bash
mkdir -p targets/clickhouse/src
echo "placeholder" > targets/clickhouse/src/.keep
./run.sh local build.sh clickhouse
```

Expected: Docker builds successfully, image loaded into kind.

- [ ] **Step 3: Deploy to local K8s**

```bash
export TARGET_SERVICE_PORT=8123
./run.sh local deploy.sh clickhouse
```

Expected: Pod is ready, port-forward active, connection env file written.

- [ ] **Step 4: Verify service is accessible**

```bash
source /tmp/autoopt-clickhouse-connection.env
curl -sf "http://$SERVICE_HOST:$SERVICE_PORT/ping"
```

Expected: `Ok.`

- [ ] **Step 5: Run workload**

```bash
./run.sh local workload.sh clickhouse
```

Expected: workload completes, `results/clickhouse/local/logs/workload-raw.log` contains `latency_p99_ms=` lines.

- [ ] **Step 6: Collect metrics**

```bash
./run.sh local collect.sh clickhouse
```

Expected: outputs key=value metrics like:
```
peak_rss_mb=XXX
cpu_pct=XXX
latency_p99_ms=XXX
```

- [ ] **Step 7: Run validation**

```bash
./run.sh local validate.sh clickhouse
```

Expected: `[validate] PASSED`

- [ ] **Step 8: Teardown**

```bash
./run.sh local teardown.sh clickhouse
```

Expected: Pod deleted, port-forward killed.

- [ ] **Step 9: Verify clean state**

```bash
kubectl --context kind-autoopt -n autoopt get pods 2>/dev/null
```

Expected: No resources found.

- [ ] **Step 10: Test integrated loop — initialize results.tsv and record baseline**

```bash
# Initialize results directory and TSV
mkdir -p results/clickhouse/local/logs
echo -e "exp_id\tbranch\tparent_branch\tcommit\tmetric_name\tmetric_value\tbaseline_value\tdelta_vs_baseline\tdelta_vs_parent\tcpu_pct\tlatency_p99_ms\terror_rate\tpod_restarts\tstatus\tdescription" > results/clickhouse/local/results.tsv

# Re-deploy to get fresh metrics for baseline
./run.sh local build.sh clickhouse
./run.sh local deploy.sh clickhouse
./run.sh local workload.sh clickhouse
./run.sh local collect.sh clickhouse > results/clickhouse/local/logs/baseline-metrics.log
./run.sh local validate.sh clickhouse

# Read baseline metric
BASELINE=$(grep "^peak_rss_mb=" results/clickhouse/local/logs/baseline-metrics.log | cut -d= -f2)
echo "Baseline peak_rss_mb: $BASELINE"

# Record baseline in results.tsv
echo -e "baseline\tautoopt/clickhouse/smoke-baseline\t-\t0000000\tpeak_rss_mb\t$BASELINE\t$BASELINE\t0.0%\t0.0%\t0\t0\t0\t0\tkeep\tbaseline (unmodified)" >> results/clickhouse/local/results.tsv

# Verify results.tsv has 2 lines (header + baseline)
wc -l results/clickhouse/local/results.tsv
```

Expected: `2 results/clickhouse/local/results.tsv`

- [ ] **Step 11: Teardown and verify cleanup.sh works**

```bash
./run.sh local teardown.sh clickhouse

# Test cleanup (dry run — no branches to delete, but should not error)
./run.sh local cleanup.sh clickhouse --tag smoke
```

Expected: both complete without errors.

- [ ] **Step 12: Verify results survived cleanup (no --all flag)**

```bash
cat results/clickhouse/local/results.tsv | head -2
```

Expected: header + baseline row still present.

- [ ] **Step 13: Clean up smoke test artifacts**

```bash
rm -rf targets/clickhouse/src/.keep results/clickhouse/
kubectl --context kind-autoopt -n autoopt get pods 2>/dev/null
```

Expected: No resources found. Clean state.

No commit needed — this is a manual verification step.

---

### Task 10: Final Polish & Documentation Commit

**Files:**
- Verify: all files present and consistent

- [ ] **Step 1: Verify complete file tree**

```bash
find . -type f | grep -v '.git/' | grep -v 'node_modules' | sort
```

Expected files:
```
./.gitignore
./docs/superpowers/plans/2026-03-22-autooptimization-impl.md
./docs/superpowers/specs/2026-03-22-autooptimization-design.md
./envs/base/build.sh
./envs/base/cleanup.sh
./envs/base/collect.sh
./envs/base/deploy.sh
./envs/base/env.conf
./envs/base/teardown.sh
./envs/base/validate.sh
./envs/base/workload.sh
./envs/local/build.sh
./envs/local/env.conf
./program.md
./run.sh
./targets/clickhouse/Dockerfile
./targets/clickhouse/hints.md
./targets/clickhouse/k8s.yaml
./targets/clickhouse/target.md
./targets/clickhouse/workload.sh
```

- [ ] **Step 2: Verify all scripts are executable**

```bash
for f in run.sh envs/base/*.sh envs/local/*.sh targets/clickhouse/workload.sh; do
  if [ ! -x "$f" ]; then echo "NOT EXECUTABLE: $f"; fi
done
```

Expected: no output (all executable).

- [ ] **Step 3: Add spec and plan docs to git**

```bash
git add docs/
git commit -m "docs: add design spec and implementation plan"
```

- [ ] **Step 4: Final verification — git log**

```bash
git log --oneline
```

Expected: ~7-8 commits covering scaffolding, run.sh, env configs, core scripts, collect/validate, cleanup, target config, program.md, and docs.
