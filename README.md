# ai-agent-usage: Multi-Tool AI CLI Usage Monitor

A unified monitoring system for tracking usage limits across multiple AI coding assistants (Claude Code, Gemini CLI, Crush, OpenCode) with cross-platform notifications and Claude Code statusline integration.

## Features

- **Claude Code**: Real-time usage % in statusline + daemon monitoring via OAuth API
- **Gemini CLI**: Daily reset notifications (midnight PT) — no API available
- **Crush**: Multi-provider support (Anthropic, OpenAI) with reset detection
- **OpenCode**: Provider detection with Anthropic API polling
- **Threshold Alerts**: Notify at 50%, 75%, 80%, 90%, 95%, 99% usage (fire once per threshold)
- **Next Threshold Display**: Statusline shows next warning threshold (e.g., `warn@75%`)
- **Cross-platform**: Linux (notify-send) + macOS (osascript) + universal bell
- **Secure**: Credentials never logged, OAuth tokens via process substitution, state files 600 perms
- **Extensible**: Plugin architecture for adding new tools

## Installation

```bash
cd /home/darvin/ai-agent-usage
bash install.sh
```

This will:
1. Copy files to `~/.local/share/ai-agent-usage`
2. Copy config to `~/.config/ai-agent-usage`
3. Configure Claude Code statusline hook
4. Create `~/.local/bin/ai-agent-usage` symlink
5. **Register daemon as a system service** (systemd on Linux, launchd on macOS)
6. **Auto-start daemon at login**

## Configuration

Edit `~/.config/ai-agent-usage/ai-agent-usage.conf`:

```bash
# Enable monitors (space-separated)
ENABLED_MONITORS="claude gemini crush opencode"

# Poll interval in seconds (min 60, default 300)
POLL_INTERVAL=300

# Gemini timezone for daily reset
GEMINI_TZ="America/Los_Angeles"

# Threshold notifications (50, 75, 80, 90, 95, 99)
# To customize, edit: ~/.local/share/ai-agent-usage/lib/thresholds.sh
# Change the THRESHOLDS array
```

### Customizing Thresholds

Edit `~/.local/share/ai-agent-usage/lib/thresholds.sh`:

```bash
# Line 5: Change this array to your preferred thresholds
THRESHOLDS=(50 75 80 90 95 99)

# Example: only alert at 75% and 90%
# THRESHOLDS=(75 90)
```

## Usage

### Daemon Mode (Auto-started via systemd/launchd)

The daemon starts automatically at login and runs in the background (no terminal needed).

```bash
# Check status (Linux)
systemctl --user status ai-agent-usage

# Check status (macOS)
launchctl list | grep ia-agent

# View logs (Linux)
journalctl --user -u ai-agent-usage -f

# View logs (macOS)
tail -f ~/Library/Logs/ai-agent-usage.log

# Stop daemon gracefully
ai-agent-usage daemon --stop

# Restart daemon (Linux)
systemctl --user restart ai-agent-usage

# Restart daemon (macOS)
launchctl stop com.ai-agent-usage.daemon
launchctl start com.ai-agent-usage.daemon
```

### One-shot Mode (Testing, Cron, Manual)

```bash
# Run monitors once and exit (useful for testing or cron jobs)
ai-agent-usage daemon --once
```

### Manual Limit Marking (Gemini & Manual Tools)

When you hit a usage limit:

```bash
# Mark Gemini limit as hit (scheduled for midnight PT reset notification)
ai-agent-usage mark-limit gemini

# Mark other tools
ai-agent-usage mark-limit crush
ai-agent-usage mark-limit opencode
```

### Claude Code Statusline

Automatic! Once installed, Claude Code will show:

```
[Claude Opus] 5h: 42% (2h13m) | 7d: 17% | ctx: 8%
```

- **Color coded**: Green <50%, Yellow 50-80%, Red >80%
- **Bell**: Rings on reset detection
- **Notification**: Desktop notification on reset

## Threshold Notifications

Usage alerts fire at these thresholds, **once per session/reset**:

| Threshold | Notification | Statusline |
|-----------|--------------|------------|
| 50% | 🔔 Usage at 50% — approaching limit! | warn@75% (next) |
| 75% | 🔔 Usage at 75% — approaching limit! | warn@80% (next) |
| 80% | 🔔 Usage at 80% — approaching limit! | warn@90% (next) |
| 90% | 🔔 Usage at 90% — approaching limit! | warn@95% (next) |
| 95% | 🔔 Usage at 95% — approaching limit! | warn@99% (next) |
| 99% | 🔔 Usage at 99% — critical limit! | (all thresholds hit) |
| Reset | 🔔 Usage reset! Now at X% | thresholds reset |

**How it works:**
1. Each monitor tracks which thresholds have been notified (per tool)
2. When usage crosses a threshold, you get **one notification**
3. Threshold state resets when the limit resets (5-hour window for Claude)
4. Statusline shows the **next threshold** you're approaching

**Example flow:**
```
Usage: 35% → [nothing] → warn@50%
Usage: 52% → [notify "at 50%!"] → warn@75%
Usage: 78% → [notify "at 75%!", "at 80%!"] → warn@90%
Usage: 15% → [reset notification] → warn@50%
```

---

## Monitor Details

### Claude Code (`monitors/claude.sh`)

- **Data source**: `~/.claude/.credentials.json` (OAuth token)
- **API**: `https://api.anthropic.com/api/oauth/usage`
- **Detects**: 20%+ usage drop OR reset_at timestamp passed
- **Notification**: Fires immediately on reset

### Gemini CLI (`monitors/gemini.sh`)

- **Data source**: `~/.gemini/oauth_creds.json`
- **Quota info**: None via API (Google doesn't expose it)
- **Strategy**: User runs `ai-agent-usage mark-limit gemini` when limit hit
- **Reset**: Scheduled for midnight Pacific Time (00:00 PT)
- **Notification**: Fires at reset time

### Crush (`monitors/crush.sh`)

- **Provider detection**: Reads `$ANTHROPIC_API_KEY`, `$OPENAI_API_KEY` env vars
- **Anthropic**: Polls Anthropic usage API (same as Claude Code)
- **OpenAI**: Attempts OpenAI billing endpoint (beta)
- **Fallback**: Manual mode if no API key found

### OpenCode (`monitors/opencode.sh`)

- **Provider detection**: Reads `~/.local/share/opencode/auth.json`
- **GitHub Copilot**: Native support (no detailed quota API available)
- **Anthropic**: Falls back to Anthropic API if key available
- **Fallback**: Manual mode for unsupported providers

## Security

- **No credential caching**: Tokens read fresh from disk each check
- **No token logging**: State files contain only percentages and timestamps
- **Process isolation**: OAuth tokens passed via curl `--config` (not command args)
- **Secure temp files**: All state/log files created with 600 permissions
- **Symlink protection**: Checks before reading/writing any temp file

## Logs

Location: `$TMPDIR/ai-agent-usage-log-<tool>-$(id -u).log`

View logs:

```bash
# Claude monitor
tail -f /tmp/ai-agent-usage-log-claude-$(id -u).log

# All monitors
tail -f /tmp/ai-agent-usage-log-*-$(id -u).log
```

## Uninstall

```bash
bash uninstall.sh
```

Completely removes ai-agent-usage:

- **Deregisters daemon service** (systemd or launchd)
- **Removes installed files** from `~/.local/share/ai-agent-usage` and `~/.config/ai-agent-usage`
- **Removes symlink** from `~/.local/bin/ai-agent-usage`
- **Cleans up runtime files** (logs, state files, PID files in `/tmp`)
- **Restores Claude Code settings** from backup (or removes statusline hook if no backup)

No traces left behind.

## Troubleshooting

### Claude Code statusline not showing

1. Check Claude Code settings: `cat ~/.claude/settings.json | grep statusLine`
2. Test manually: `cat ~/.claude/statusline.sh` should be installed
3. Reinstall: `bash install.sh`

### Daemon not running

```bash
# Check service status (Linux)
systemctl --user status ai-agent-usage

# Check service status (macOS)
launchctl list | grep ai-agent-usage

# View logs (Linux)
journalctl --user -u ai-agent-usage -f

# View logs (macOS)
tail -f ~/Library/Logs/ai-agent-usage.log

# Try one-shot mode to test monitors
ai-agent-usage daemon --once
```

### Monitor not detecting limit reset

Check state file:

```bash
# Claude
cat /tmp/ai-agent-usage-state-claude-$(id -u)

# Gemini (should have "limit_hit|timestamp")
cat /tmp/ai-agent-usage-state-gemini-$(id -u)
```

### Threshold notifications not firing

Check threshold tracking:

```bash
# View threshold state (50:yes,75:no,...)
cat /tmp/ai-agent-usage-thresholds-claude-$(id -u)

# Reset thresholds manually (will re-fire on next check)
rm /tmp/ai-agent-usage-thresholds-*-$(id -u)
```

## Architecture

```
~/.local/share/ai-agent-usage/
├── lib/
│   ├── notify.sh      # Cross-platform notifications
│   ├── state.sh       # Secure state file management
│   └── log.sh         # Safe logging
├── monitors/
│   ├── claude.sh      # Claude Code monitor
│   ├── gemini.sh      # Gemini CLI monitor
│   ├── crush.sh       # Crush monitor
│   └── opencode.sh    # OpenCode monitor
├── statusline.sh      # Claude Code statusline
├── daemon.sh          # Orchestrator
└── bin/
    └── ai-agent-usage # Wrapper script
```

## Environment Variables

- `TMPDIR` - Override temp directory (default: `/tmp`)
- `ANTHROPIC_API_KEY` - Crush/OpenCode Anthropic monitoring
- `OPENAI_API_KEY` - Crush OpenAI monitoring
- `CLAUDE_USAGE_POLL_INTERVAL` - Override poll interval (deprecated, use config file)

## Future Enhancements

- Per-threshold customization via config (currently hardcoded to 50, 75, 80, 90, 95, 99)
- Additional monitor providers (e.g., Claude Web)
- OpenAI streaming billing API support
- GitHub Copilot quota endpoint (when available)

## License

MIT

## Support

For issues, check:
1. Logs: `/tmp/ai-agent-usage-log-*.log`
2. State files: `/tmp/ai-agent-usage-state-*`
3. Credentials file permissions: `ls -la ~/.claude/.credentials.json`
