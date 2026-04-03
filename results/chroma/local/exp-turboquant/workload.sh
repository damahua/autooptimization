#!/bin/bash
# IDENTICAL workload to baseline — same data, same queries
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/../baseline/workload.sh"
