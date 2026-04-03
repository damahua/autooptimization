#!/bin/bash
# IDENTICAL teardown to baseline
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/../baseline/teardown.sh"
