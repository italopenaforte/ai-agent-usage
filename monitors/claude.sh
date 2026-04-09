#!/bin/bash
# monitors/claude.sh — Claude Code usage monitor daemon
# Polls OAuth API, detects resets, sends notifications
# Usage: monitors/claude.sh [--once]

set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/ia-agent-usage"
CONFIG_DIR="${HOME}/.config/ia-agent-usage"
CREDENTIALS_FILE="${HOME}/.claude/.credentials.json"
API_URL="https://api.anthropic.com/api/oauth/usage"

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
if (( POLL_INTERVAL < 60 )); then
    POLL_INTERVAL=60
fi

ONE_SHOT=false
if [[ "${1:-}" == "--once" ]]; then
    ONE_SHOT=true
fi

# Guard against symlink attacks
state_file=$(get_state_file "claude")
if [[ -L "$state_file" ]]; then
    echo "ERROR: state file is a symlink, refusing to run" >&2
    exit 1
fi

get_token() {
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        log_message "claude" "ERROR: Credentials file not found: $CREDENTIALS_FILE"
        return 1
    fi

    local perms
    perms=$(stat -c '%a' "$CREDENTIALS_FILE" 2>/dev/null || stat -f '%Lp' "$CREDENTIALS_FILE" 2>/dev/null || echo "unknown")
    if [[ "$perms" != "600" && "$perms" != "400" && "$perms" != "unknown" ]]; then
        log_message "claude" "WARNING: credentials file has loose permissions ($perms)"
    fi

    local token
    token=$(grep -o '"claudeAiOauth"[^}]*"accessToken":"[^"]*"' "$CREDENTIALS_FILE" 2>/dev/null | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4 || true)
    if [[ -z "$token" ]]; then
        log_message "claude" "ERROR: No access token found in credentials file"
        return 1
    fi
    echo "$token"
}

fetch_usage() {
    local token="$1"
    local response
    local http_code

    # Fetch with timeout
    response=$(curl -s -w "\n%{http_code}" --max-time 10 \
        "$API_URL" \
        --config <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null) || {
        log_message "claude" "ERROR: Failed to connect to API"
        return 1
    }

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "401" ]]; then
        log_message "claude" "ERROR: Authentication failed (401)"
        return 1
    elif [[ "$http_code" == "429" ]]; then
        log_message "claude" "Rate limited (429)"
        return 1
    elif [[ "$http_code" != "200" ]]; then
        log_message "claude" "API error: HTTP $http_code"
        return 1
    fi

    echo "$body"
}

check_and_notify() {
    local token
    token=$(get_token) || return 1

    local usage
    usage=$(fetch_usage "$token") || return 1

    local five_pct five_reset seven_pct
    if command -v jq &>/dev/null; then
        five_pct=$(echo "$usage" | jq -r '.rate_limits.five_hour.used_percentage // 0')
        five_reset=$(echo "$usage" | jq -r '.rate_limits.five_hour.resets_at // 0')
        seven_pct=$(echo "$usage" | jq -r '.rate_limits.seven_day.used_percentage // 0')
    else
        # Fallback: minimal parsing
        five_pct=$(echo "$usage" | grep -o '"five_hour".*"used_percentage":[0-9.]*' | grep -o '[0-9.]*$' || echo "0")
        five_reset=$(echo "$usage" | grep -o '"resets_at":[0-9]*' | grep -o '[0-9]*$' || echo "0")
        seven_pct=$(echo "$usage" | grep -o '"seven_day".*"used_percentage":[0-9.]*' | grep -o '[0-9.]*$' || echo "0")
    fi

    local five_pct_int=${five_pct%.*}
    local seven_pct_int=${seven_pct%.*}
    local now
    now=$(date +%s)

    # Reset countdown
    local remaining=""
    if (( five_reset > now )); then
        local diff=$(( five_reset - now ))
        local h=$(( diff / 3600 ))
        local m=$(( (diff % 3600) / 60 ))
        remaining="${h}h${m}m"
    else
        remaining="now"
    fi

    log_message "claude" "5h: ${five_pct_int}% (resets ${remaining}) | 7d: ${seven_pct_int}%"

    # Reset detection
    local prev_state=""
    prev_state=$(read_state "claude")
    local prev_pct="" prev_reset=""
    if [[ -n "$prev_state" ]]; then
        prev_pct=$(echo "$prev_state" | cut -d'|' -f1 2>/dev/null || true)
        prev_reset=$(echo "$prev_state" | cut -d'|' -f2 2>/dev/null || true)
    fi

    local reset_detected=false
    if [[ -n "$prev_pct" && -n "$prev_reset" ]]; then
        if [[ "$prev_pct" =~ ^[0-9]+(\.[0-9]+)?$ && "$prev_reset" =~ ^[0-9]+$ ]]; then
            local drop=$(( ${prev_pct%.*} - five_pct_int ))
            if (( drop > 20 )); then
                reset_detected=true
            elif (( now > prev_reset )) && (( five_pct_int < ${prev_pct%.*} )); then
                reset_detected=true
            fi
        fi
    fi

    # Save state
    write_state "claude" "${five_pct}|${five_reset}"

    if $reset_detected; then
        log_message "claude" "SESSION RESET DETECTED — usage dropped to ${five_pct_int}%"
        notify "Claude Code" "Usage reset! Now at ${five_pct_int}%"
        reset_thresholds "claude"
    fi

    # Threshold notifications
    check_and_notify_thresholds "claude" "$five_pct" "Claude Code" >/dev/null
}

# Main
if $ONE_SHOT; then
    check_and_notify || true
    exit 0
fi

log_message "claude" "Monitor started (poll interval: ${POLL_INTERVAL}s)"
trap 'log_message "claude" "Monitor stopped"; exit 0' INT TERM

while true; do
    check_and_notify || true
    sleep "$POLL_INTERVAL"
done
