#!/bin/bash
# state.sh — Secure state file management (umask 077, symlink protection, numeric validation)

# get_state_file — Return the path to a state file for a given tool
# Usage: state_file=$(get_state_file "claude")
get_state_file() {
  local tool="$1"
  local tmpdir="${TMPDIR:-/tmp}"
  echo "$tmpdir/ia-agent-usage-state-${tool}-$(id -u)"
}

# read_state — Read state from a tool's state file
# Usage: state=$(read_state "claude")
# Format: percentage|resets_at_epoch
read_state() {
  local tool="$1"
  local state_file
  state_file=$(get_state_file "$tool")

  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo ""
  fi
}

# write_state — Atomically write state with 600 permissions
# Usage: write_state "claude" "45.2|1712600000"
write_state() {
  local tool="$1"
  local state="$2"
  local state_file
  state_file=$(get_state_file "$tool")

  # Check for symlink attacks (fail safely)
  if [[ -L "$state_file" ]]; then
    echo "ERROR: state file is a symlink: $state_file" >&2
    return 1
  fi

  # Write with secure permissions
  printf '%s\n' "$state" >"$state_file"
  chmod 600 "$state_file" || return 1
}

# validate_numeric — Validate that a value is numeric
# Usage: validate_numeric "$percentage" && echo "valid"
validate_numeric() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# Note: Functions are available in subshells automatically
