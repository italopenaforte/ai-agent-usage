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
source "$INSTALL_DIR/lib/secrets.sh"

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
    # Check secrets (keyring → secrets.conf → env var) for a configured provider key.
    # Assign to local vars so key values never reach the outer shell environment.
    local _k
    if _k=$(read_secret "ANTHROPIC_API_KEY" 2>/dev/null) && [[ -n "$_k" ]]; then
        unset _k
        echo "anthropic"
    elif _k=$(read_secret "OPENAI_API_KEY" 2>/dev/null) && [[ -n "$_k" ]]; then
        unset _k
        echo "openai"
    elif _k=$(read_secret "GEMINI_API_KEY" 2>/dev/null) && [[ -n "$_k" ]]; then
        unset _k
        echo "gemini"
    else
        unset _k
        # Try to read default from crush config
        if [[ -f "$CRUSH_PROVIDERS" ]] && command -v jq &>/dev/null; then
            jq -r '.default_provider // "unknown"' "$CRUSH_PROVIDERS" 2>/dev/null || echo "unknown"
        else
            echo "unknown"
        fi
    fi
}

fetch_anthropic_usage() {
    local api_key
    api_key=$(read_secret "ANTHROPIC_API_KEY") || {
        log_message "crush" "ERROR: ANTHROPIC_API_KEY not found — run: ai-agent-usage set-key ANTHROPIC_API_KEY"
        return 1
    }

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" --max-time 10 \
        "https://api.anthropic.com/api/oauth/usage" \
        --config <(printf 'header = "Authorization: Bearer %s"\n' "$api_key") \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null) || {
        unset api_key
        log_message "crush" "ERROR: Failed to connect to Anthropic API"
        return 1
    }
    unset api_key

    http_code=$(echo "$response" | tail -1)
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
    local api_key
    api_key=$(read_secret "OPENAI_API_KEY") || {
        log_message "crush" "ERROR: OPENAI_API_KEY not found — run: ai-agent-usage set-key OPENAI_API_KEY"
        return 1
    }

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" --max-time 10 \
        "https://api.openai.com/dashboard/billing/usage" \
        --config <(printf 'header = "Authorization: Bearer %s"\n' "$api_key") \
        -H "Content-Type: application/json" 2>/dev/null) || {
        unset api_key
        log_message "crush" "ERROR: Failed to connect to OpenAI API"
        return 1
    }
    unset api_key

    http_code=$(echo "$response" | tail -1)
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
        log_message "crush" "WARNING: No active provider detected. Run: ai-agent-usage set-key ANTHROPIC_API_KEY"
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
