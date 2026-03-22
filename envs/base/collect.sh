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
