# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ia-agent-usage** is a unified usage monitoring system for AI CLI tools (Claude Code, Gemini CLI, Crush, OpenCode). It provides:
- Real-time usage display in Claude Code's statusline
- Threshold-based notifications (50%, 75%, 80%, 90%, 95%, 99%)
- Reset detection and notifications
- Cross-platform support (Linux + macOS)
- Plugin architecture for extending to new tools

**Not a service**: Runs as user processes, no daemon installation required.

## Architecture

### Core Design: Plugin Monitor System

```
daemon.sh (orchestrator)
├── monitors/claude.sh      (polls OAuth API, ~80 LOC)
├── monitors/gemini.sh      (midnight PT reset scheduling, ~90 LOC)
├── monitors/crush.sh       (provider detection + API polling, ~165 LOC)
└── monitors/opencode.sh    (provider detection + API polling, ~165 LOC)

Shared libraries (lib/)
├── notify.sh               (cross-platform notifications)
├── state.sh                (secure temp file management)
├── log.sh                  (safe append-only logging)
└── thresholds.sh           (threshold tracking per tool)
```

**Key principle**: Each monitor is **independent**. One crash doesn't kill others. All monitors are sourced into daemon subshells.

### Data Flow

1. **daemon.sh** runs on poll interval (default 300s)
2. For each enabled monitor, daemon sources `monitors/<tool>.sh --once`
3. Monitor:
   - Reads credentials from tool's config (OAuth, API keys, or state files)
   - Fetches usage from provider API (or uses manual state for Gemini)
   - Compares against previous state (in `/tmp/ia-agent-usage-state-<tool>-$(id -u)`)
   - Detects reset (20%+ drop or resets_at timestamp passed)
   - Checks threshold crossings (50%, 75%, etc.)
   - Sends notifications via `lib/notify.sh`
4. **statusline.sh** runs per Claude Code message (reads stdin JSON, outputs formatted bar)

### Credential Handling (Security Critical)

- **Claude Code**: OAuth token from `~/.claude/.credentials.json`
  - Passed to curl via `--config <(printf ...)` (not in process args)
  - API: `https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer $token`

- **Gemini CLI**: OAuth token from `~/.gemini/oauth_creds.json`
  - No API for remaining quota → uses manual marking + scheduled notifications

- **Crush/OpenCode**: Detects provider via env vars or config
  - `$ANTHROPIC_API_KEY` → polls Anthropic API
  - `$OPENAI_API_KEY` → polls OpenAI endpoint
  - Falls back to manual marking if no API key

**Never log credentials, never cache tokens.**

### State Files (All in `/tmp`)

| File | Format | Purpose |
|------|--------|---------|
| `ia-agent-usage-state-<tool>-$(id -u)` | `percentage\|resets_at_epoch` | Previous usage snapshot |
| `ia-agent-usage-thresholds-<tool>-$(id -u)` | `50:yes,75:no,...` | Which thresholds have fired |
| `ia-agent-usage-log-<tool>-$(id -u).log` | Timestamped lines | Debug logs |
| `ia-agent-usage-daemon-$(id -u).pid` | PID number | Daemon process ID |

All created with 600 permissions. Symlink attack checks before access.

## Key Files & Responsibilities

### Monitors (`monitors/*.sh`)

**claude.sh**: OAuth API polling
- Detects resets: `usage_drop > 20%` OR `now > resets_at && usage < prev_usage`
- Emits: reset notification + threshold notifications
- ~180 LOC

**gemini.sh**: Manual limit + scheduled resets
- No API available; user calls `ia-agent-usage mark-limit gemini`
- Schedules reset notification for **midnight Pacific Time**
- Emits: reset notification + threshold notifications
- ~100 LOC

**crush.sh**: Provider detection + API polling
- Detects active provider: env vars (`$ANTHROPIC_API_KEY`, `$OPENAI_API_KEY`) or config
- Falls back to manual if no API key
- Same reset logic as Claude (20%+ drop)
- ~180 LOC

**opencode.sh**: Same as Crush but reads from `~/.local/share/opencode/auth.json`
- ~180 LOC

### Libraries (`lib/*.sh`)

**notify.sh**: ~25 LOC
- `notify "Title" "Message"` — sends desktop notification
- Linux: `notify-send`, macOS: `osascript`, fallback: terminal bell

**state.sh**: ~50 LOC
- `get_state_file "tool"` — path to state file
- `read_state "tool"` — parse `percentage|resets_at` format
- `write_state "tool" "percentage|resets_at"` — atomically save (600 perms)
- `validate_numeric "$val"` — regex check for `[0-9]+(\.[0-9]+)?`

**log.sh**: ~30 LOC
- `log_message "tool" "msg"` — append to log with timestamp
- Never logs credentials (by design in callers)

**thresholds.sh**: ~100 LOC
- `get_thresholds_state "tool"` — read which thresholds fired
- `check_and_notify_thresholds "tool" "pct" "display_name"` — fire on threshold crossing
- `reset_thresholds "tool"` — clear state on reset
- `get_next_threshold "tool"` — return next unfired threshold (for statusline)

### Special Scripts

**statusline.sh**: ~120 LOC
- Invoked **per Claude Code message** (reads stdin JSON with rate_limits)
- Outputs colored bar: `[Model] 5h: 42% (2h13m) | 7d: 17% | ctx: 8% | warn@75%`
- Performs reset detection (same as daemon)
- Calls threshold check (fires during active session)
- Color: green <50%, yellow 50-80%, red >80%

**daemon.sh**: ~120 LOC
- Entry point: runs all enabled monitors on loop
- Modes: foreground, background, `--once`, `--stop`
- PID management, trap handling, subshell isolation for crashes

**install.sh**: ~70 LOC
- Installs to `~/.local/share/ia-agent-usage` + `~/.config`
- Configures Claude Code `settings.json` statusline hook
- Creates `~/.local/bin/ia-agent-usage` wrapper

## Development Tasks

### Test a monitor with mock data
```bash
# Simulate Claude usage at 75%
export HOME=/home/darvin
source ~/.local/share/ia-agent-usage/lib/thresholds.sh
source ~/.local/share/ia-agent-usage/lib/notify.sh
check_and_notify_thresholds "claude" "75.0" "Claude Code"
cat /tmp/ia-agent-usage-thresholds-claude-$(id -u)  # Should show 50:yes,75:yes,...
```

### Test statusline output
```bash
# Test with mock JSON
cat <<'EOF' | ~/.local/share/ia-agent-usage/statusline.sh
{
  "model": {"display_name": "Claude Opus"},
  "rate_limits": {
    "five_hour": {"used_percentage": 42.5, "resets_at": 1712952000},
    "seven_day": {"used_percentage": 17.3, "resets_at": 1713500000}
  },
  "context_window": {"used_percentage": 8.1}
}
EOF
# Expected: [Claude Opus] 5h: 42% (Xh Xm) | 7d: 17% | ctx: 8% | warn@50%
```

### Test daemon one-shot
```bash
~/.local/share/ia-agent-usage/daemon.sh --once
tail -5 /tmp/ia-agent-usage-log-claude-$(id -u).log
```

### Test a monitor in isolation
```bash
~/.local/share/ia-agent-usage/monitors/claude.sh --once
```

### View all logs
```bash
tail -f /tmp/ia-agent-usage-log-*-$(id -u).log
```

### Check thresholds
```bash
# See which thresholds have fired for each tool
for f in /tmp/ia-agent-usage-thresholds-*-$(id -u); do
  tool=$(basename "$f" | cut -d- -f4)
  echo "$tool: $(cat "$f")"
done
```

### Install development copy
```bash
cd /home/darvin/ia-agent-usage
bash install.sh  # Copies all files to ~/.local/share/ia-agent-usage
```

### Reinstall and test
```bash
bash install.sh && ~/.local/share/ia-agent-usage/daemon.sh --once
```

## Adding a New Monitor

1. Create `monitors/<tool>.sh` (~180 LOC template)
   - Source: `lib/state.sh`, `lib/notify.sh`, `lib/log.sh`, `lib/thresholds.sh`
   - Implement `check_and_notify()` function
   - Read credentials from tool's config location
   - Fetch usage from API (or implement manual marking like Gemini)
   - Call `check_and_notify_thresholds()` on usage
   - Call `reset_thresholds()` on reset

2. Update `ia-agent-usage.conf`: add to `ENABLED_MONITORS`

3. Test: `./monitors/<tool>.sh --once`

4. Example: See `monitors/crush.sh` for multi-provider pattern

## Security Notes

**Strengths:**
- No credential caching
- OAuth tokens via process substitution (hidden from `ps aux`)
- State files 600 perms with symlink checks
- No credentials in logs

**Known issues:**
- API keys in env vars visible in `ps` (document risk, or store in config)
- No HTTPS cert validation (add `--cacert` if needed)
- Shared `/tmp` on multi-user systems (document limitation)

See README troubleshooting and security sections for user-facing notes.

## Git Workflow

- Main branch: stable, tested
- Commits: one feature per commit with clear message
- Test before committing: `daemon.sh --once`

## Common Issues

### Statusline not appearing in Claude Code
- Check: `cat ~/.claude/settings.json | grep statusLine`
- Reinstall: `bash install.sh`
- Test: `cat <<'EOF' | ~/.local/share/ia-agent-usage/statusline.sh`

### Monitor crashes are silent
- Check logs: `tail /tmp/ia-agent-usage-log-<tool>-$(id -u).log`
- Run with `--once` for immediate output

### Credentials permission warning
- Gemini: `chmod 600 ~/.gemini/oauth_creds.json`
- Claude: `chmod 600 ~/.claude/.credentials.json`

### API calls failing (401, 429)
- Token expired: re-authenticate with the tool's CLI
- Rate limited: reduce `POLL_INTERVAL` in config (min 60s)
