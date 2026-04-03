#!/bin/bash
# Profile Chroma memory using /proc/smaps and jemalloc
# smaps gives per-region breakdown; jemalloc confirms allocation source
set -euo pipefail

MODE="${1:-docker}"  # "docker" or "k8s"
EXEC_CMD="docker exec autoopt-chroma"
[ "$MODE" = "k8s" ] && {
  POD=$(kubectl --context kind-autoopt -n autoopt get pod -l app=autoopt-chroma \
    -o jsonpath='{.items[0].metadata.name}')
  EXEC_CMD="kubectl --context kind-autoopt -n autoopt exec $POD --"
}

echo "=== PROFILE: Chroma memory ==="

# 1. /proc/1/status — high-level memory summary
echo "--- /proc/1/status ---"
$EXEC_CMD cat /proc/1/status | grep -E "^(Vm|Rss|Threads)"

# 2. smaps — per-region RSS breakdown
# This is the KEY profiling data for Chroma: tells you heap vs mmap vs file-backed
echo ""
echo "--- smaps: RSS by type ---"
$EXEC_CMD cat /proc/1/smaps 2>/dev/null | awk '
  /^[0-9a-f]/ {
    mapping = (NF >= 6) ? $NF : "[anon]"
  }
  /^Rss:/ {
    rss = $2
    if (mapping == "[heap]") heap += rss
    else if (mapping == "[stack]") stack += rss
    else if (mapping ~ /\.so/ || mapping ~ /^\//) file += rss
    else anon += rss
    total += rss
  }
  END {
    printf "total:       %.1f MB\n", total/1024
    printf "heap:        %.1f MB (%.1f%%)\n", heap/1024, heap*100/total
    printf "anon_mmap:   %.1f MB (%.1f%%)\n", anon/1024, anon*100/total
    printf "file_backed: %.1f MB (%.1f%%)\n", file/1024, file*100/total
    printf "stack:       %.1f MB\n", stack/1024
  }'

# 3. Top anonymous regions by RSS (likely HNSW + vector data)
echo ""
echo "--- Top 10 memory regions by RSS ---"
$EXEC_CMD cat /proc/1/smaps 2>/dev/null | awk '
  /^[0-9a-f]/ {
    mapping = (NF >= 6) ? $NF : "[anon]"
  }
  /^Rss:/ {
    if ($2 > 0) printf "%.1f MB  %s\n", $2/1024, mapping
  }
' | sort -rn | head -10

# 4. Theoretical minimum calculation
echo ""
echo "--- Theoretical minimum ---"
echo "Raw vectors: 50000 x 768 x 4 bytes = 146 MB"
echo "HNSW graph (M=16): ~50K x 16 x 2 levels x 4 bytes = 6 MB"
echo "Metadata + docs: ~8 MB"
echo "Theoretical min: ~160 MB"

echo "=== PROFILE COMPLETE ==="
