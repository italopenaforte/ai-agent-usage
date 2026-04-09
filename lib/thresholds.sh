#!/bin/bash
# thresholds.sh — Threshold-based notifications
# Notifies when usage crosses 50%, 75%, 80%, 90%, 95%, 99%
# Tracks which thresholds have been hit to avoid duplicate notifications

# Define thresholds
THRESHOLDS=(50 75 80 90 95 99)

# get_thresholds_state — Read which thresholds have been hit
# Usage: state=$(get_thresholds_state "claude")
# Format: "50:yes,75:no,80:yes,..."
get_thresholds_state() {
    local tool="$1"
    local tmpdir="${TMPDIR:-/tmp}"
    local thresholds_file="$tmpdir/ai-agent-usage-thresholds-${tool}-$(id -u)"

    if [[ -f "$thresholds_file" ]]; then
        cat "$thresholds_file"
    else
        # Initialize: all thresholds not hit
        local init=""
        for t in "${THRESHOLDS[@]}"; do
            [[ -n "$init" ]] && init="${init},"
            init="${init}${t}:no"
        done
        echo "$init"
    fi
}

# save_thresholds_state — Save which thresholds have been hit
# Usage: save_thresholds_state "claude" "50:yes,75:no,80:yes,..."
save_thresholds_state() {
    local tool="$1"
    local state="$2"
    local tmpdir="${TMPDIR:-/tmp}"
    local thresholds_file="$tmpdir/ai-agent-usage-thresholds-${tool}-$(id -u)"

    # Check for symlink attacks
    if [[ -L "$thresholds_file" ]]; then
        echo "ERROR: thresholds file is a symlink: $thresholds_file" >&2
        return 1
    fi

    printf '%s\n' "$state" >"$thresholds_file"
    chmod 600 "$thresholds_file" 2>/dev/null || true
}

# check_and_notify_thresholds — Check if usage crossed any threshold and notify
# Usage: check_and_notify_thresholds "claude" 42.5 "Claude Code"
# Returns: updated thresholds state
check_and_notify_thresholds() {
    local tool="$1"
    local current_pct="$2"
    local tool_name="$3"

    local current_int=${current_pct%.*}
    local prev_state
    prev_state=$(get_thresholds_state "$tool")

    # Parse previous state into associative array
    declare -A threshold_map
    for entry in ${prev_state//,/ }; do
        local t="${entry%:*}"
        local hit="${entry#*:}"
        threshold_map[$t]="$hit"
    done

    # Check each threshold
    local new_state=""
    local notified=false
    local next_threshold=""

    for t in "${THRESHOLDS[@]}"; do
        local was_hit="${threshold_map[$t]:-no}"
        local is_hit="no"

        # Mark as hit if we've crossed or reached this threshold
        if (( current_int >= t )); then
            is_hit="yes"

            # Notify only on transition from "no" to "yes"
            if [[ "$was_hit" == "no" ]]; then
                notified=true
                notify "$tool_name" "Usage at ${current_int}% — approaching limit!"
            fi
        else
            # Current usage below this threshold
            is_hit="no"
            if [[ -z "$next_threshold" ]]; then
                next_threshold="$t"
            fi
        fi

        # Build new state
        [[ -n "$new_state" ]] && new_state="${new_state},"
        new_state="${new_state}${t}:${is_hit}"
    done

    # Save updated state
    save_thresholds_state "$tool" "$new_state"

    # Return state for caller
    echo "$new_state"
}

# reset_thresholds — Reset all thresholds (call on limit reset)
# Usage: reset_thresholds "claude"
reset_thresholds() {
    local tool="$1"
    local init=""
    for t in "${THRESHOLDS[@]}"; do
        [[ -n "$init" ]] && init="${init},"
        init="${init}${t}:no"
    done
    save_thresholds_state "$tool" "$init"
}

# get_next_threshold — Get the next threshold warning
# Usage: next=$(get_next_threshold "claude")
get_next_threshold() {
    local tool="$1"
    local prev_state
    prev_state=$(get_thresholds_state "$tool")

    # Parse state
    declare -A threshold_map
    for entry in ${prev_state//,/ }; do
        local t="${entry%:*}"
        local hit="${entry#*:}"
        threshold_map[$t]="$hit"
    done

    # Find first unhit threshold
    for t in "${THRESHOLDS[@]}"; do
        if [[ "${threshold_map[$t]:-no}" == "no" ]]; then
            echo "$t"
            return 0
        fi
    done

    echo "99+"  # All thresholds hit
}

# Export functions
export -f get_thresholds_state 2>/dev/null || true
export -f save_thresholds_state 2>/dev/null || true
export -f check_and_notify_thresholds 2>/dev/null || true
export -f reset_thresholds 2>/dev/null || true
export -f get_next_threshold 2>/dev/null || true
