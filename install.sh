#!/bin/bash
# install.sh — Install ia-agent-usage and configure Claude Code statusline hook

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/share/ia-agent-usage"
CONFIG_DIR="${HOME}/.config/ia-agent-usage"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

echo "Installing ia-agent-usage..."

# Create directories
mkdir -p "$INSTALL_DIR"/{lib,monitors,bin}
mkdir -p "$CONFIG_DIR"

# Copy files
echo "Copying files..."
cp "$SCRIPT_DIR"/lib/*.sh "$INSTALL_DIR/lib/" 2>/dev/null || true
cp "$SCRIPT_DIR"/monitors/*.sh "$INSTALL_DIR/monitors/" 2>/dev/null || true
cp "$SCRIPT_DIR"/{statusline.sh,daemon.sh} "$INSTALL_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/ia-agent-usage.conf" "$CONFIG_DIR/ia-agent-usage.conf" 2>/dev/null || true

# Create wrapper scripts in ~/.local/share/ia-agent-usage/bin
cat >"$INSTALL_DIR/bin/ia-agent-usage" <<'EOF'
#!/bin/bash
INSTALL_DIR="${HOME}/.local/share/ia-agent-usage"
CONFIG_DIR="${HOME}/.config/ia-agent-usage"

# Source config
if [[ -f "$CONFIG_DIR/ia-agent-usage.conf" ]]; then
  source "$CONFIG_DIR/ia-agent-usage.conf"
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
  *)
    echo "Usage: ia-agent-usage {daemon|mark-limit TOOL}"
    exit 1
    ;;
esac
EOF

chmod +x "$INSTALL_DIR/bin/ia-agent-usage"

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
    jq ".statusLine.command = \"$statusline_path\"" "$CLAUDE_SETTINGS" >"$CLAUDE_SETTINGS.tmp"
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
ln -sf "$INSTALL_DIR/bin/ia-agent-usage" "${HOME}/.local/bin/ia-agent-usage"

# Verify installation
echo ""
echo "✓ Installation complete!"
echo "  Install dir: $INSTALL_DIR"
echo "  Config dir: $CONFIG_DIR"
echo "  Claude Code statusline configured"
echo ""
echo "Next steps:"
echo "  1. Edit $CONFIG_DIR/ia-agent-usage.conf to enable monitors"
echo "  2. Run: ia-agent-usage daemon &"
echo "  3. To stop: killall ia-agent-usage"
