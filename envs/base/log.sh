#!/bin/bash
# Shared logging utilities for autooptimization framework.
# Source this file in any script: source "$FRAMEWORK_ROOT/envs/base/log.sh"
#
# Provides structured logging with timestamps so the developer/owner
# can see exactly what's happening at each step.
#
# Log levels:
#   log_step    — major step boundary (BEFORE/AFTER)
#   log_status  — in-progress status update
#   log_result  — final result with metrics
#   log_error   — error with context
#   log_warn    — warning (non-fatal)

# Experiment log file (appended to, never overwritten)
EXPERIMENT_LOG="${EXPERIMENT_LOG:-}"
if [ -n "$FRAMEWORK_ROOT" ] && [ -n "${TARGET:-}" ] && [ -n "${ENV:-}" ]; then
  EXPERIMENT_LOG="$FRAMEWORK_ROOT/results/${TARGET}/${ENV}/experiment.log"
  mkdir -p "$(dirname "$EXPERIMENT_LOG")" 2>/dev/null || true
fi

_ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S"
}

_log() {
  local level="$1"; shift
  local script="${SCRIPT_NAME:-unknown}"
  local msg="[$(_ts)] [$level] [$script] $*"
  echo "$msg"
  if [ -n "$EXPERIMENT_LOG" ]; then
    echo "$msg" >> "$EXPERIMENT_LOG" 2>/dev/null || true
  fi
}

log_step() {
  local phase="$1"; shift  # BEFORE, AFTER
  _log "STEP" "--- $phase --- $*"
}

log_status() {
  _log "STATUS" "$*"
}

log_result() {
  _log "RESULT" "$*"
}

log_error() {
  _log "ERROR" "$*" >&2
}

log_warn() {
  _log "WARN" "$*"
}

# Print a separator line for readability
log_separator() {
  local msg="$*"
  echo ""
  echo "================================================================"
  echo "  $msg"
  echo "================================================================"
  echo ""
  if [ -n "$EXPERIMENT_LOG" ]; then
    echo "" >> "$EXPERIMENT_LOG" 2>/dev/null || true
    echo "================================================================" >> "$EXPERIMENT_LOG" 2>/dev/null || true
    echo "  $msg" >> "$EXPERIMENT_LOG" 2>/dev/null || true
    echo "================================================================" >> "$EXPERIMENT_LOG" 2>/dev/null || true
  fi
}
