#!/bin/bash
# Chroma benchmark workload: 50K embeddings x 768-dim, cosine similarity
# Deterministic data (SHA256-based), 5 phases: create, insert, query, concurrent, get
# This script was used for all Chroma experiments (baseline + TurboQuant)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Use the workload.sh from the chroma setup branch (309 lines, full benchmark)
WORKLOAD_SCRIPT="$REPO_ROOT/targets/chroma/workload.sh"

if [ -f "$WORKLOAD_SCRIPT" ]; then
  # workload.sh expects SERVICE_HOST and SERVICE_PORT
  export SERVICE_HOST="${SERVICE_HOST:-localhost}"
  export SERVICE_PORT="${SERVICE_PORT:-8000}"
  exec "$WORKLOAD_SCRIPT"
else
  # Fallback: extract from git if not on disk
  echo "[workload] Extracting workload.sh from autoopt/chroma/setup branch..."
  TMPFILE=$(mktemp)
  git -C "$REPO_ROOT" show autoopt/chroma/setup:targets/chroma/workload.sh > "$TMPFILE"
  chmod +x "$TMPFILE"
  export SERVICE_HOST="${SERVICE_HOST:-localhost}"
  export SERVICE_PORT="${SERVICE_PORT:-8000}"
  exec "$TMPFILE"
fi
