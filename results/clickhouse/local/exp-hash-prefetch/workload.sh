#!/bin/bash
# IDENTICAL workload to baseline — same data, same queries, same measurement
# This ensures the only variable is the code change
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/../baseline/workload.sh"
