#!/bin/bash
# notify.sh — Cross-platform notifications (Linux + macOS) with fallback to bell

# Usage: notify "Title" "Message"
notify() {
  local title="$1"
  local message="$2"

  # Terminal bell (works everywhere)
  printf '\a'

  # Platform-specific notifications
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux: use notify-send if available
    if command -v notify-send &>/dev/null; then
      notify-send -u normal -i dialog-information "$title" "$message" 2>/dev/null || true
    fi
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS: use osascript
    osascript -e "display notification \"$message\" with title \"$title\" sound name \"Glass\"" 2>/dev/null || true
  fi
}

# Note: Function is available in subshells automatically
