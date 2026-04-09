#!/bin/bash
# monitors/gemini.sh — Google Gemini CLI usage monitor
# Google has no API for remaining quota. Strategy:
# - User runs: ia-agent-usage mark-limit gemini (when they hit the wall)
# - System stores timestamp and schedules next reset notification for midnight PT
# - Optional: test with lightweight request to detect limit restoration
#
# Usage: monitors/gemini.sh [--once]

set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/ia-agent-usage"
CONFIG_DIR="${HOME}/.config/ia-agent-usage"
GEMINI_CREDS="${HOME}/.gemini/oauth_creds.json"

# Source libraries
source "$INSTALL_DIR/lib/state.sh"
source "$INSTALL_DIR/lib/notify.sh"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/thresholds.sh"

# Source config
if [[ -f "$CONFIG_DIR/ia-agent-usage.conf" ]]; then
    source "$CONFIG_DIR/ia-agent-usage.conf"
fi

POLL_INTERVAL="${POLL_INTERVAL:-300}"
GEMINI_TZ="${GEMINI_TZ:-America/Los_Angeles}"
ONE_SHOT=false

if [[ "${1:-}" == "--once" ]]; then
    ONE_SHOT=true
fi

# Guard against symlink attacks
state_file=$(get_state_file "gemini")
if [[ -L "$state_file" ]]; then
    echo "ERROR: state file is a symlink, refusing to run" >&2
    exit 1
fi

get_token() {
    if [[ ! -f "$GEMINI_CREDS" ]]; then
        log_message "gemini" "ERROR: Gemini credentials not found: $GEMINI_CREDS"
        return 1
    fi

    # Try to extract access_token, refresh if expired
    local token
    token=$(grep -o '"access_token":"[^"]*"' "$GEMINI_CREDS" | head -1 | cut -d'"' -f4 || true)
    if [[ -z "$token" ]]; then
        log_message "gemini" "ERROR: No access token found in credentials"
        return 1
    fi
    echo "$token"
}

# Calculate next midnight PT in epoch seconds
next_midnight_pt() {
    # Get current time in PT, then compute midnight PT
    local now_pt
    now_pt=$(date -d 'TZ="America/Los_Angeles" now' +%s 2>/dev/null || date +%s)

    # Midnight PT = today at 00:00 PT (or tomorrow if past midnight)
    local midnight_epoch
    midnight_epoch=$(date -d 'TZ="America/Los_Angeles" tomorrow 00:00' +%s 2>/dev/null || echo "0")

    # Fallback: if date command doesn't support -d, estimate 24 hours from now
    if [[ "$midnight_epoch" == "0" ]]; then
        midnight_epoch=$(( now_pt + 86400 ))
    fi

    echo "$midnight_epoch"
}

check_and_notify() {
    local current_state
    current_state=$(read_state "gemini")

    # Parse previous state: limit_hit|timestamp  OR  limit_restored|timestamp
    local prev_status="" prev_timestamp=""
    if [[ -n "$current_state" ]]; then
        prev_status=$(echo "$current_state" | cut -d'|' -f1 2>/dev/null || true)
        prev_timestamp=$(echo "$current_state" | cut -d'|' -f2 2>/dev/null || true)
    fi

    local now
    now=$(date +%s)

    # Case 1: Limit was hit previously, check if it's reset time
    if [[ "$prev_status" == "limit_hit" && -n "$prev_timestamp" ]]; then
        local reset_epoch
        reset_epoch=$(next_midnight_pt)

        if (( now >= reset_epoch )); then
            # Time to reset! Send notification
            log_message "gemini" "Gemini limit reset time (midnight PT) — daily quota restored"
            notify "Gemini CLI" "Daily quota limit reset at midnight PT. Ready to use again!"

            # Clear state and thresholds
            write_state "gemini" "ready|$now"
            reset_thresholds "gemini"
        else
            # Not yet reset time, show countdown
            local hours=$(( (reset_epoch - now) / 3600 ))
            local mins=$(( ((reset_epoch - now) % 3600) / 60 ))
            log_message "gemini" "Limit in effect — resets in ${hours}h${mins}m at midnight PT"
        fi
    elif [[ "$prev_status" == "ready" || -z "$prev_status" ]]; then
        # No limit currently marked. Can optionally test with a lightweight API call here
        # For now, just return (user will mark limit when they hit it)
        log_message "gemini" "Ready (no limit marked)"
    fi
}

# Main
if $ONE_SHOT; then
    check_and_notify || true
    exit 0
fi

log_message "gemini" "Monitor started (poll interval: ${POLL_INTERVAL}s, TZ: $GEMINI_TZ)"
trap 'log_message "gemini" "Monitor stopped"; exit 0' INT TERM

while true; do
    check_and_notify || true
    sleep "$POLL_INTERVAL"
done
