#!/bin/bash
# monitors/crush.sh — Crush CLI usage monitor
# Crush supports multiple providers (Anthropic, OpenAI, Gemini, etc.)
# Strategy:
# - Read provider config from ~/.local/share/crush/providers.json
# - If $ANTHROPIC_API_KEY is set: poll Anthropic usage API
# - If $OPENAI_API_KEY is set: check OpenAI billing endpoint
# - Otherwise: manual mode (user marks limit, system schedules reset)
#
# Usage: monitors/crush.sh [--once]

set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/ai-agent-usage"
CONFIG_DIR="${HOME}/.config/ai-agent-usage"
CRUSH_PROVIDERS="${HOME}/.local/share/crush/providers.json"

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
state_file=$(get_state_file "crush")
if [[ -L "$state_file" ]]; then
    echo "ERROR: state file is a symlink, refusing to run" >&2
    exit 1
fi

detect_provider() {
    # Check for env vars indicating active provider
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        echo "anthropic"
    elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
        echo "openai"
    elif [[ -n "${GEMINI_API_KEY:-}" ]]; then
        echo "gemini"
    else
        # Try to read default from crush config
        if [[ -f "$CRUSH_PROVIDERS" ]] && command -v jq &>/dev/null; then
            jq -r '.default_provider // "unknown"' "$CRUSH_PROVIDERS" 2>/dev/null || echo "unknown"
        else
            echo "unknown"
        fi
    fi
}

fetch_anthropic_usage() {
    local api_key="${ANTHROPIC_API_KEY}"
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" --max-time 10 \
        "https://api.anthropic.com/api/oauth/usage" \
        --config <(printf 'header = "Authorization: Bearer %s"\n' "$api_key") \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null) || {
        log_message "crush" "ERROR: Failed to connect to Anthropic API"
        return 1
    }

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "401" ]]; then
        log_message "crush" "ERROR: Anthropic authentication failed (401)"
        return 1
    elif [[ "$http_code" != "200" ]]; then
        log_message "crush" "Anthropic API error: HTTP $http_code"
        return 1
    fi

    echo "$body"
}

fetch_openai_usage() {
    local api_key="${OPENAI_API_KEY}"
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" --max-time 10 \
        "https://api.openai.com/dashboard/billing/usage" \
        --config <(printf 'header = "Authorization: Bearer %s"\n' "$api_key") \
        -H "Content-Type: application/json" 2>/dev/null) || {
        log_message "crush" "ERROR: Failed to connect to OpenAI API"
        return 1
    }

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        log_message "crush" "OpenAI API error: HTTP $http_code"
        return 1
    fi

    echo "$body"
}

check_and_notify() {
    local provider
    provider=$(detect_provider)

    if [[ "$provider" == "unknown" ]]; then
        log_message "crush" "WARNING: No active provider detected. Set \$ANTHROPIC_API_KEY or \$OPENAI_API_KEY"
        return 0
    fi

    log_message "crush" "Checking $provider provider usage..."

    local usage
    if [[ "$provider" == "anthropic" ]]; then
        usage=$(fetch_anthropic_usage) || return 1
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
            log_message "crush" "Anthropic: 5h window at ${five_pct_int}% (resets in $(( remaining / 3600 ))h)"
        fi

        # Save state and detect reset
        local prev_state
        prev_state=$(read_state "crush")
        local prev_pct=""
        if [[ -n "$prev_state" ]]; then
            prev_pct=$(echo "$prev_state" | cut -d'|' -f1 2>/dev/null || true)
        fi

        if [[ -n "$prev_pct" && "$prev_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            local drop=$(( ${prev_pct%.*} - five_pct_int ))
            if (( drop > 20 )); then
                log_message "crush" "RESET DETECTED for Anthropic provider"
                notify "Crush (Anthropic)" "Usage reset! Now at ${five_pct_int}%"
                reset_thresholds "crush"
            fi
        fi

        write_state "crush" "${five_pct}|${five_reset}|anthropic"

        # Threshold notifications
        check_and_notify_thresholds "crush" "$five_pct" "Crush (Anthropic)" >/dev/null

    elif [[ "$provider" == "openai" ]]; then
        # OpenAI usage endpoint returns different structure
        usage=$(fetch_openai_usage) || return 1
        log_message "crush" "OpenAI: Retrieved usage data (manual limit reset scheduling not yet implemented)"
        # TODO: Parse OpenAI usage and implement reset detection
    fi
}

# Main
if $ONE_SHOT; then
    check_and_notify || true
    exit 0
fi

log_message "crush" "Monitor started (poll interval: ${POLL_INTERVAL}s)"
trap 'log_message "crush" "Monitor stopped"; exit 0' INT TERM

while true; do
    check_and_notify || true
    sleep "$POLL_INTERVAL"
done
