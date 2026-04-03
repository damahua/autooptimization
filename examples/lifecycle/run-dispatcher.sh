#!/bin/bash
# EXAMPLE: Pipeline Dispatcher (Legacy)
# PURPOSE: Shows how to dispatch lifecycle scripts with env-specific overrides.
#   The pattern: base scripts + env-specific variants (e.g., build-kind.sh).
# NOTE: The AI agent does NOT use this dispatcher. It reads program.md and
#   runs commands directly. Preserved as a reference and used by the demo.
set -euo pipefail

ENV="${1:?Usage: ./run-dispatcher.sh <env> <script> <target>}"
SCRIPT="${2:?Usage: ./run-dispatcher.sh <env> <script> <target>}"
TARGET="${3:?Usage: ./run-dispatcher.sh <env> <script> <target>}"

LIFECYCLE_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORK_ROOT="$(cd "$LIFECYCLE_DIR/../.." && pwd)"
export FRAMEWORK_ROOT TARGET ENV

# Validate target exists
if [ ! -d "$FRAMEWORK_ROOT/targets/$TARGET" ]; then
  echo "[run-dispatcher] ERROR: Target '$TARGET' not found in targets/" >&2; exit 1
fi

# Source config: base first, then env-specific override
set -a
source "$LIFECYCLE_DIR/env.conf"
ENV_CONF="$LIFECYCLE_DIR/env-${ENV}.conf"
if [ -f "$ENV_CONF" ]; then
  source "$ENV_CONF"
fi
set +a

# Resolve script: env-specific variant (e.g., build-kind.sh) if exists, otherwise base
SCRIPT_BASE="${SCRIPT%.sh}"
ENV_SCRIPT="$LIFECYCLE_DIR/${SCRIPT_BASE}-${ENV}.sh"
BASE_SCRIPT="$LIFECYCLE_DIR/$SCRIPT"

if [ -f "$ENV_SCRIPT" ]; then
  exec "$ENV_SCRIPT" "$TARGET"
elif [ -f "$BASE_SCRIPT" ]; then
  exec "$BASE_SCRIPT" "$TARGET"
else
  echo "[run-dispatcher] ERROR: Script '$SCRIPT' not found" >&2; exit 1
fi
