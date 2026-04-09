#!/bin/bash
# log.sh — Secure append-only logging (never logs credentials)

# log_message — Append a message to the log file (600 perms, no credentials)
# Usage: log_message "claude" "Reset detected"
log_message() {
  local tool="$1"
  local message="$2"
  local tmpdir="${TMPDIR:-/tmp}"
  local log_file="$tmpdir/ai-agent-usage-log-${tool}-$(id -u).log"

  # Check for symlink attacks
  if [[ -L "$log_file" ]]; then
    echo "ERROR: log file is a symlink: $log_file" >&2
    return 1
  fi

  # Append with timestamp
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$message" >>"$log_file"
  # Ensure secure permissions
  chmod 600 "$log_file" 2>/dev/null || true
}

# Note: Function is available in subshells automatically
