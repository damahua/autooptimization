#!/bin/bash
# Collect peak RSS from Chroma container
# Key metric: VmHWM from /proc/1/status (true peak RSS)
set -euo pipefail

MODE="${1:-docker}"  # "docker" (default) or "k8s"

echo "=== COLLECT: Chroma metrics ==="

if [ "$MODE" = "k8s" ]; then
  POD=$(kubectl --context kind-autoopt -n autoopt get pod -l app=autoopt-chroma \
    -o jsonpath='{.items[0].metadata.name}')
  echo "[collect] Pod: $POD"

  echo "[collect] /proc/1/status:"
  kubectl --context kind-autoopt -n autoopt exec "$POD" -- cat /proc/1/status | grep -E "^Vm(RSS|HWM|Peak|Size)"

  echo ""
  echo "[collect] Memory region breakdown (smaps summary):"
  kubectl --context kind-autoopt -n autoopt exec "$POD" -- cat /proc/1/smaps 2>/dev/null | \
    awk '/^Rss:/{total+=$2} END{printf "total_rss_kb=%d (%.1f MB)\n", total, total/1024}'

  RESTARTS=$(kubectl --context kind-autoopt -n autoopt get pod "$POD" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}')
  echo "[collect] Pod restarts: $RESTARTS"
else
  echo "[collect] Docker container: autoopt-chroma"

  echo "[collect] /proc/1/status:"
  docker exec autoopt-chroma cat /proc/1/status | grep -E "^Vm(RSS|HWM|Peak|Size)"

  echo ""
  echo "[collect] Memory region breakdown (smaps summary):"
  docker exec autoopt-chroma cat /proc/1/smaps 2>/dev/null | \
    awk '/^Rss:/{total+=$2} END{printf "total_rss_kb=%d (%.1f MB)\n", total, total/1024}'

  # Detailed breakdown: heap vs anon vs file-backed
  echo ""
  echo "[collect] RSS by type:"
  docker exec autoopt-chroma cat /proc/1/smaps 2>/dev/null | awk '
    /^[0-9a-f]/ { mapping = (NF >= 6) ? $NF : "[anon]" }
    /^Rss:/ {
      rss = $2
      if (mapping == "[heap]") heap += rss
      else if (mapping ~ /\.so/ || mapping ~ /^\//) file += rss
      else anon += rss
      total += rss
    }
    END {
      printf "  heap:        %.1f MB\n", heap/1024
      printf "  anon_mmap:   %.1f MB\n", anon/1024
      printf "  file_backed: %.1f MB\n", file/1024
      printf "  total:       %.1f MB\n", total/1024
    }'
fi

echo "=== COLLECT COMPLETE ==="
