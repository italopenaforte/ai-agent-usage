#!/bin/bash
# install.sh — Install ai-agent-usage and configure Claude Code statusline hook

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/share/ai-agent-usage"
CONFIG_DIR="${HOME}/.config/ai-agent-usage"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

echo "Installing ai-agent-usage..."

# Create directories
mkdir -p "$INSTALL_DIR"/{lib,monitors,bin}
mkdir -p "$CONFIG_DIR"

# Create secrets.conf with 600 perms if absent (umask 177 → mode 600)
if [[ ! -f "$CONFIG_DIR/secrets.conf" ]]; then
  (umask 177; touch "$CONFIG_DIR/secrets.conf")
  printf '# ai-agent-usage secrets — do not chmod above 600\n' >> "$CONFIG_DIR/secrets.conf"
  printf '# Format: KEY=value  (no shell syntax, no quotes, no export)\n' >> "$CONFIG_DIR/secrets.conf"
  printf '# Store keys with: ai-agent-usage set-key ANTHROPIC_API_KEY\n' >> "$CONFIG_DIR/secrets.conf"
fi

# Copy files
echo "Copying files..."
cp "$SCRIPT_DIR"/lib/*.sh "$INSTALL_DIR/lib/" 2>/dev/null || true
cp "$SCRIPT_DIR"/monitors/*.sh "$INSTALL_DIR/monitors/" 2>/dev/null || true
cp "$SCRIPT_DIR"/{statusline.sh,daemon.sh} "$INSTALL_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/ai-agent-usage.conf" "$CONFIG_DIR/ai-agent-usage.conf" 2>/dev/null || true

# Create wrapper scripts in ~/.local/share/ai-agent-usage/bin
cat >"$INSTALL_DIR/bin/ai-agent-usage" <<'EOF'
#!/bin/bash
INSTALL_DIR="${HOME}/.local/share/ai-agent-usage"
CONFIG_DIR="${HOME}/.config/ai-agent-usage"

# Source config
if [[ -f "$CONFIG_DIR/ai-agent-usage.conf" ]]; then
  source "$CONFIG_DIR/ai-agent-usage.conf"
fi

# Source libraries
source "$INSTALL_DIR/lib/notify.sh"
source "$INSTALL_DIR/lib/state.sh"
source "$INSTALL_DIR/lib/log.sh"

# Handle subcommands
case "${1:-}" in
  daemon)
    exec "$INSTALL_DIR/daemon.sh" "${@:2}"
    ;;
  mark-limit)
    tool="$2"
    timestamp=$(date +%s)
    state_file=$(get_state_file "$tool")
    write_state "$tool" "limit_hit|$timestamp"
    log_message "$tool" "Limit marked as hit at $timestamp"
    echo "Marked $tool limit as hit. Notification scheduled for next reset."
    ;;
  set-key)
    key_name="${2:-}"
    if [[ -z "$key_name" ]]; then
      echo "Usage: ai-agent-usage set-key KEY_NAME" >&2
      echo "Example: ai-agent-usage set-key ANTHROPIC_API_KEY" >&2
      exit 1
    fi
    source "$INSTALL_DIR/lib/secrets.sh"
    # -r: no backslash escape  -s: silent (no echo to terminal)
    printf "Enter value for %s (input hidden): " "$key_name" >&2
    read -rs key_value
    echo >&2
    if [[ -z "$key_value" ]]; then
      echo "ERROR: Empty value — nothing stored." >&2
      exit 1
    fi
    store_secret "$key_name" "$key_value"
    unset key_value
    ;;
  *)
    echo "Usage: ai-agent-usage {daemon|mark-limit TOOL|set-key KEY_NAME}"
    exit 1
    ;;
esac
EOF

chmod +x "$INSTALL_DIR/bin/ai-agent-usage"

# Set permissions on all scripts
chmod 755 "$INSTALL_DIR/lib"/*.sh
chmod 755 "$INSTALL_DIR/monitors"/*.sh 2>/dev/null || true
chmod 755 "$INSTALL_DIR"/*.sh

# Configure Claude Code statusline hook
echo "Configuring Claude Code statusline..."
statusline_path="$INSTALL_DIR/statusline.sh"

if [[ -f "$CLAUDE_SETTINGS" ]]; then
  # Backup original
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.backup"

  # Update statusline config (using jq if available, else manual)
  if command -v jq &>/dev/null; then
    jq ".statusLine.type = \"command\" | .statusLine.command = \"$statusline_path\"" "$CLAUDE_SETTINGS" >"$CLAUDE_SETTINGS.tmp"
    mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
  else
    # Manual sed replacement (fallback)
    sed -i.bak "s|\"statusLine\".*|\"statusLine\": { \"type\": \"command\", \"command\": \"$statusline_path\" }|g" "$CLAUDE_SETTINGS"
  fi
else
  # Create minimal settings.json
  mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
  cat >"$CLAUDE_SETTINGS" <<EOJSON
{
  "statusLine": {
    "type": "command",
    "command": "$statusline_path"
  }
}
EOJSON
fi

# Create symlink in PATH
mkdir -p "${HOME}/.local/bin"
ln -sf "$INSTALL_DIR/bin/ai-agent-usage" "${HOME}/.local/bin/ai-agent-usage"

# Register daemon as a system service
install_service() {
  local os; os="$(uname -s)"
  if [[ "$os" == "Linux" ]]; then
    _install_systemd
  elif [[ "$os" == "Darwin" ]]; then
    _install_launchd
  else
    echo "  Note: auto-start not supported on $os — run: ai-agent-usage daemon &"
  fi
}

_install_systemd() {
  if ! command -v systemctl &>/dev/null; then
    echo "  systemctl not found — skipping service registration."
    echo "  Run manually: ai-agent-usage daemon &"
    return
  fi
  local unit_dir="${HOME}/.config/systemd/user"
  mkdir -p "$unit_dir"
  cp "$SCRIPT_DIR/service/ai-agent-usage.service" "$unit_dir/ai-agent-usage.service"
  pkill -f "ai-agent-usage daemon" 2>/dev/null || true
  systemctl --user daemon-reload
  systemctl --user enable --now ai-agent-usage || {
    echo "  Warning: systemctl enable failed (is systemd running as user?)."
    echo "  Try: loginctl enable-linger $(whoami)"
  }
  echo "  systemd user service enabled."
  echo "  Logs: journalctl --user -u ai-agent-usage -f"
}

_install_launchd() {
  local plist_dir="${HOME}/Library/LaunchAgents"
  local plist_dst="$plist_dir/com.ai-agent-usage.daemon.plist"
  mkdir -p "$plist_dir" "${HOME}/Library/Logs"
  sed \
    -e "s|__INSTALL_DIR__|${INSTALL_DIR}|g" \
    -e "s|__HOME__|${HOME}|g" \
    "$SCRIPT_DIR/service/ai-agent-usage.plist" > "$plist_dst"
  pkill -f "ai-agent-usage daemon" 2>/dev/null || true
  launchctl unload "$plist_dst" 2>/dev/null || true
  launchctl load -w "$plist_dst"
  echo "  launchd agent loaded."
  echo "  Logs: tail -f ~/Library/Logs/ai-agent-usage.log"
}

install_service

# Verify installation
echo ""
echo "✓ Installation complete!"
echo "  Install dir: $INSTALL_DIR"
echo "  Config dir: $CONFIG_DIR"
echo "  Claude Code statusline configured"
echo ""
echo "Next steps:"
echo "  1. Edit $CONFIG_DIR/ai-agent-usage.conf to enable monitors"
echo "  2. Daemon auto-starts at login (systemd/launchd registered above)"
echo "  3. To stop: ai-agent-usage daemon --stop"
echo "  4. Status (Linux): systemctl --user status ai-agent-usage"
