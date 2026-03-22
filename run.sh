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
