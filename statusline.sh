#!/bin/bash
# statusline.sh — Claude Code statusline display
# Shows usage %, reset countdown, color coding, and bell on reset detection.
# Input: JSON from Claude Code's stdin with rate_limits and context_window
# Output: Colored status line: [Model] 5h: 23% (2h13m) | 7d: 41% | ctx: 8%

set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/ai-agent-usage"
CONFIG_DIR="${HOME}/.config/ai-agent-usage"

# Source libraries
source "$INSTALL_DIR/lib/state.sh"
source "$INSTALL_DIR/lib/notify.sh"
source "$INSTALL_DIR/lib/thresholds.sh"

# Guard against symlink attacks
state_file=$(get_state_file "claude")
if [[ -L "$state_file" ]]; then
    echo "[error] state file is a symlink, refusing to run" >&2
    exit 1
fi

# Read JSON from stdin
INPUT=$(cat)

# Parse JSON using jq (fallback to simple grep if jq not available)
if command -v jq &>/dev/null; then
    MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "?"')
    CTX_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
    FIVE_PCT=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null || true)
    FIVE_RESET=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null || true)
    SEVEN_PCT=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null || true)
else
    # Minimal fallback parsing (jq recommended)
    MODEL="?"
    CTX_PCT=0
    FIVE_PCT=""
    FIVE_RESET=""
    SEVEN_PCT=""
fi

# Current folder and git branch
FOLDER=$(basename "$PWD")
GIT_BRANCH=$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ -n "$GIT_BRANCH" && "$GIT_BRANCH" != "HEAD" ]]; then
    LOCATION="${FOLDER} (${GIT_BRANCH})"
else
    LOCATION="$FOLDER"
fi

# Rate limits not available yet (first message in session)
if [[ -z "$FIVE_PCT" ]]; then
    echo "${LOCATION} | [${MODEL}] ctx: ${CTX_PCT}% | usage: waiting..."
    exit 0
fi

FIVE_PCT_INT=${FIVE_PCT%.*}
SEVEN_PCT_INT=${SEVEN_PCT%.*}
NOW=$(date +%s)

# Reset detection
PREV_STATE=$(read_state "claude")
PREV_PCT=""
PREV_RESET=""
if [[ -n "$PREV_STATE" ]]; then
    PREV_PCT=$(echo "$PREV_STATE" | cut -d'|' -f1 2>/dev/null || true)
    PREV_RESET=$(echo "$PREV_STATE" | cut -d'|' -f2 2>/dev/null || true)
fi

RESET_DETECTED=false
if [[ -n "$PREV_PCT" && -n "$PREV_RESET" ]]; then
    if [[ "$PREV_PCT" =~ ^[0-9]+(\.[0-9]+)?$ && "$PREV_RESET" =~ ^[0-9]+$ ]]; then
        DROP=$(( ${PREV_PCT%.*} - FIVE_PCT_INT ))
        if (( DROP > 20 )); then
            RESET_DETECTED=true
        elif (( NOW > PREV_RESET )) && (( FIVE_PCT_INT < ${PREV_PCT%.*} )); then
            RESET_DETECTED=true
        fi
    fi
fi

# Save state
write_state "claude" "${FIVE_PCT}|${FIVE_RESET}"

# Notify on reset
if $RESET_DETECTED; then
    notify "Claude Code" "Usage reset! Now at ${FIVE_PCT_INT}%"
    reset_thresholds "claude"
fi

# Threshold notifications (per-message, won't re-fire once notified)
check_and_notify_thresholds "claude" "$FIVE_PCT" "Claude Code" >/dev/null

# Color coding
color_for_pct() {
    local pct=$1
    if (( pct < 50 )); then
        printf "\033[32m"  # green
    elif (( pct < 80 )); then
        printf "\033[33m"  # yellow
    else
        printf "\033[31m"  # red
    fi
}
RST="\033[0m"

FIVE_COLOR=$(color_for_pct "$FIVE_PCT_INT")
SEVEN_COLOR=$(color_for_pct "$SEVEN_PCT_INT")

# Reset countdown
COUNTDOWN=""
if [[ -n "$FIVE_RESET" ]]; then
    REMAINING=$(( FIVE_RESET - NOW ))
    if (( REMAINING > 0 )); then
        HOURS=$(( REMAINING / 3600 ))
        MINS=$(( (REMAINING % 3600) / 60 ))
        COUNTDOWN="${HOURS}h${MINS}m"
    else
        COUNTDOWN="now"
    fi
fi

# Next threshold warning
NEXT_THRESHOLD=$(get_next_threshold "claude")
if [[ "$NEXT_THRESHOLD" != "99+" && -n "$NEXT_THRESHOLD" ]]; then
    NEXT_WARN=" | \033[33mwarn@${NEXT_THRESHOLD}%%${RST}"
else
    NEXT_WARN=""
fi

# Output
printf "%s | [%s] ${FIVE_COLOR}5h: %s%%${RST} (%s) | ${SEVEN_COLOR}7d: %s%%${RST} | ctx: %s%%${NEXT_WARN}\n" \
    "$LOCATION" "$MODEL" "$FIVE_PCT_INT" "$COUNTDOWN" "$SEVEN_PCT_INT" "$CTX_PCT"
