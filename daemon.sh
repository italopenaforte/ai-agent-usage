#!/bin/bash
# daemon.sh — Orchestrator for multi-tool monitors
# Runs all enabled monitors in sequence, with crash isolation
# Usage:
#   daemon.sh           # Run in foreground, loop forever
#   daemon.sh &         # Run in background
#   daemon.sh --once    # Single pass, then exit
#   daemon.sh --stop    # Stop any running daemon

set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/ia-agent-usage"
CONFIG_DIR="${HOME}/.config/ia-agent-usage"
PID_FILE="${TMPDIR:-/tmp}/ia-agent-usage-daemon-$(id -u).pid"

# Source libraries
source "$INSTALL_DIR/lib/state.sh"
source "$INSTALL_DIR/lib/notify.sh"
source "$INSTALL_DIR/lib/log.sh"

# Source config
if [[ -f "$CONFIG_DIR/ia-agent-usage.conf" ]]; then
    source "$CONFIG_DIR/ia-agent-usage.conf"
else
    # Defaults
    ENABLED_MONITORS="claude"
    POLL_INTERVAL=300
    LOG_LEVEL="info"
fi

ONE_SHOT=false
STOP_MODE=false

if [[ "${1:-}" == "--once" ]]; then
    ONE_SHOT=true
elif [[ "${1:-}" == "--stop" ]]; then
    STOP_MODE=true
fi

# Guard against symlink attacks
if [[ -L "$PID_FILE" ]]; then
    echo "ERROR: PID file is a symlink, refusing to run" >&2
    exit 1
fi

log_daemon() {
    local msg="$1"
    log_message "daemon" "$msg"
}

stop_daemon() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$PID_FILE"
            log_daemon "Stopped daemon (PID $pid)"
            echo "Daemon stopped."
        else
            rm -f "$PID_FILE"
            echo "No running daemon found."
        fi
    else
        echo "No daemon PID file found."
    fi
}

run_monitor() {
    local monitor="$1"
    local monitor_script="$INSTALL_DIR/monitors/${monitor}.sh"

    if [[ ! -f "$monitor_script" ]]; then
        log_daemon "WARNING: Monitor script not found: $monitor_script"
        return 1
    fi

    if [[ ! -x "$monitor_script" ]]; then
        log_daemon "WARNING: Monitor script not executable: $monitor_script"
        return 1
    fi

    # Run monitor in subshell to isolate crashes
    (
        set +e
        "$monitor_script" --once
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
            log_daemon "Monitor '$monitor' exited with code $exit_code"
        fi
        exit 0
    ) || true
}

run_monitors_once() {
    local monitors_str="$ENABLED_MONITORS"
    local monitors=($monitors_str)

    for monitor in "${monitors[@]}"; do
        run_monitor "$monitor"
    done
}

# Handle stop mode
if $STOP_MODE; then
    stop_daemon
    exit 0
fi

# Create or verify PID file
if [[ -f "$PID_FILE" ]]; then
    local existing_pid
    existing_pid=$(cat "$PID_FILE")
    if kill -0 "$existing_pid" 2>/dev/null; then
        echo "ERROR: Daemon already running (PID $existing_pid)"
        exit 1
    else
        rm -f "$PID_FILE"
    fi
fi

# Write PID file
(umask 077; printf '%s\n' "$$" >"$PID_FILE") || {
    echo "ERROR: Failed to create PID file: $PID_FILE" >&2
    exit 1
}

log_daemon "Daemon started (PID: $$, monitors: $ENABLED_MONITORS, interval: ${POLL_INTERVAL}s)"

# Main loop
trap 'log_daemon "Daemon stopping"; rm -f "$PID_FILE"; exit 0' INT TERM

if $ONE_SHOT; then
    run_monitors_once
    rm -f "$PID_FILE"
    exit 0
fi

while true; do
    run_monitors_once
    sleep "$POLL_INTERVAL"
done
