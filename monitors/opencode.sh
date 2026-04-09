#!/bin/bash
# monitors/opencode.sh — OpenCode AI CLI usage monitor
# OpenCode supports multiple providers:
# - GitHub Copilot (native support via auth.json)
# - Anthropic, OpenAI (via API keys)
#
# Strategy:
# - Read provider from ~/.local/share/opencode/auth.json
# - If Copilot: direct auth token available
# - If API key provider: poll corresponding API
# - Otherwise: manual mode (user marks limit)
#
# Usage: monitors/opencode.sh [--once]

set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/ai-agent-usage"
CONFIG_DIR="${HOME}/.config/ai-agent-usage"
OPENCODE_AUTH="${HOME}/.local/share/opencode/auth.json"

# Source libraries
source "$INSTALL_DIR/lib/state.sh"
source "$INSTALL_DIR/lib/notify.sh"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/thresholds.sh"

# Source config
if [[ -f "$CONFIG_DIR/ai-agent-usage.conf" ]]; then
    source "$CONFIG_DIR/ai-agent-usage.conf"
fi

POLL_INTERVAL="${POLL_INTERVAL:-300}"
ONE_SHOT=false

if [[ "${1:-}" == "--once" ]]; then
    ONE_SHOT=true
fi

# Guard against symlink attacks
state_file=$(get_state_file "opencode")
if [[ -L "$state_file" ]]; then
    echo "ERROR: state file is a symlink, refusing to run" >&2
    exit 1
fi

detect_provider() {
    # Check OpenCode auth file for configured providers
    if [[ -f "$OPENCODE_AUTH" ]]; then
        if command -v jq &>/dev/null; then
            # Try to find any configured provider
            jq -r 'keys[0]' "$OPENCODE_AUTH" 2>/dev/null || echo "unknown"
        else
            # Fallback: check for github-copilot key in file
            if grep -q "github-copilot" "$OPENCODE_AUTH" 2>/dev/null; then
                echo "github-copilot"
            else
                echo "unknown"
            fi
        fi
    else
        echo "unknown"
    fi
}

fetch_copilot_usage() {
    # GitHub Copilot usage endpoint (if available)
    # Note: GitHub Copilot doesn't expose detailed quota via public API
    # For now, log that monitoring is not yet available for Copilot
    log_message "opencode" "GitHub Copilot quota monitoring not yet available via API"
    return 0
}

fetch_anthropic_via_opencode() {
    # If OpenCode is using Anthropic provider via $ANTHROPIC_API_KEY
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        return 1
    fi

    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" --max-time 10 \
        "https://api.anthropic.com/api/oauth/usage" \
        --config <(printf 'header = "Authorization: Bearer %s"\n' "$ANTHROPIC_API_KEY") \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null) || {
        log_message "opencode" "ERROR: Failed to connect to Anthropic API"
        return 1
    }

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        log_message "opencode" "Anthropic API error: HTTP $http_code"
        return 1
    fi

    echo "$body"
}

check_and_notify() {
    local provider
    provider=$(detect_provider)

    if [[ "$provider" == "unknown" ]]; then
        log_message "opencode" "WARNING: No configured provider detected. Configure OpenCode auth."
        return 0
    fi

    log_message "opencode" "Checking $provider provider usage..."

    if [[ "$provider" == "github-copilot" ]]; then
        fetch_copilot_usage || true

    elif [[ "$provider" == "anthropic" ]] || [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        local usage
        usage=$(fetch_anthropic_via_opencode) || return 1

        local five_pct five_reset
        if command -v jq &>/dev/null; then
            five_pct=$(echo "$usage" | jq -r '.rate_limits.five_hour.used_percentage // 0')
            five_reset=$(echo "$usage" | jq -r '.rate_limits.five_hour.resets_at // 0')
        else
            five_pct=$(echo "$usage" | grep -o '"five_hour".*"used_percentage":[0-9.]*' | grep -o '[0-9.]*$' || echo "0")
            five_reset=$(echo "$usage" | grep -o '"resets_at":[0-9]*' | grep -o '[0-9]*$' || echo "0")
        fi

        local five_pct_int=${five_pct%.*}
        local now=$(date +%s)
        local remaining=""
        if (( five_reset > now )); then
            remaining=$(( five_reset - now ))
            log_message "opencode" "Anthropic: 5h window at ${five_pct_int}% (resets in $(( remaining / 3600 ))h)"
        fi

        # Save state and detect reset
        local prev_state
        prev_state=$(read_state "opencode")
        local prev_pct=""
        if [[ -n "$prev_state" ]]; then
            prev_pct=$(echo "$prev_state" | cut -d'|' -f1 2>/dev/null || true)
        fi

        if [[ -n "$prev_pct" && "$prev_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            local drop=$(( ${prev_pct%.*} - five_pct_int ))
            if (( drop > 20 )); then
                log_message "opencode" "RESET DETECTED for Anthropic provider"
                notify "OpenCode (Anthropic)" "Usage reset! Now at ${five_pct_int}%"
                reset_thresholds "opencode"
            fi
        fi

        write_state "opencode" "${five_pct}|${five_reset}|anthropic"

        # Threshold notifications
        check_and_notify_thresholds "opencode" "$five_pct" "OpenCode (Anthropic)" >/dev/null
    fi
}

# Main
if $ONE_SHOT; then
    check_and_notify || true
    exit 0
fi

log_message "opencode" "Monitor started (poll interval: ${POLL_INTERVAL}s)"
trap 'log_message "opencode" "Monitor stopped"; exit 0' INT TERM

while true; do
    check_and_notify || true
    sleep "$POLL_INTERVAL"
done
