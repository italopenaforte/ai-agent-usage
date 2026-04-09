#!/bin/bash
# uninstall.sh — Uninstall ai-agent-usage

set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/ai-agent-usage"
CONFIG_DIR="${HOME}/.config/ai-agent-usage"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

echo "Uninstalling ai-agent-usage..."

# Deregister daemon from system service
uninstall_service() {
  local os; os="$(uname -s)"
  if [[ "$os" == "Linux" ]]; then
    _uninstall_systemd
  elif [[ "$os" == "Darwin" ]]; then
    _uninstall_launchd
  else
    pkill -f "ai-agent-usage daemon" 2>/dev/null || true
  fi
}

_uninstall_systemd() {
  local unit_file="${HOME}/.config/systemd/user/ai-agent-usage.service"
  if command -v systemctl &>/dev/null; then
    systemctl --user disable --now ai-agent-usage 2>/dev/null || true
    systemctl --user daemon-reload
  fi
  rm -f "$unit_file"
}

_uninstall_launchd() {
  local plist_dst="${HOME}/Library/LaunchAgents/com.ai-agent-usage.daemon.plist"
  if [[ -f "$plist_dst" ]]; then
    launchctl unload -w "$plist_dst" 2>/dev/null || true
    rm -f "$plist_dst"
  fi
}

uninstall_service

# Remove files
echo "Removing installed files..."
rm -rf "$INSTALL_DIR"
rm -rf "$CONFIG_DIR"
rm -f "${HOME}/.local/bin/ai-agent-usage"

# Remove runtime state files from /tmp
echo "Removing runtime state files..."
rm -f /tmp/ai-agent-usage-state-*-"$(id -u)"
rm -f /tmp/ai-agent-usage-thresholds-*-"$(id -u)"
rm -f /tmp/ai-agent-usage-log-*-"$(id -u)".log
rm -f /tmp/ai-agent-usage-daemon-"$(id -u)".pid

# Remove Claude Code statusline hook (restore from backup if exists)
if [[ -f "$CLAUDE_SETTINGS.backup" ]]; then
  echo "Restoring Claude Code settings from backup..."
  mv "$CLAUDE_SETTINGS.backup" "$CLAUDE_SETTINGS"
elif [[ -f "$CLAUDE_SETTINGS" ]]; then
  # Manual removal of statusLine entry
  if command -v jq &>/dev/null; then
    jq 'del(.statusLine)' "$CLAUDE_SETTINGS" >"$CLAUDE_SETTINGS.tmp"
    mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
  fi
fi

echo "✓ Uninstall complete!"
