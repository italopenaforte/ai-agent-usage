#!/bin/bash
# uninstall.sh — Uninstall ia-agent-usage

set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/ia-agent-usage"
CONFIG_DIR="${HOME}/.config/ia-agent-usage"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

echo "Uninstalling ia-agent-usage..."

# Kill any running daemon
pkill -f "ia-agent-usage daemon" 2>/dev/null || true
sleep 1

# Remove files
echo "Removing installed files..."
rm -rf "$INSTALL_DIR"
rm -rf "$CONFIG_DIR"
rm -f "${HOME}/.local/bin/ia-agent-usage"

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
