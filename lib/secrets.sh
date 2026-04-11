#!/bin/bash
# lib/secrets.sh — Secure credential reading and storage
#
# Priority order (highest to lowest):
#   1. OS keyring  — Linux: secret-tool (libsecret), macOS: security (Keychain)
#   2. secrets.conf — ~/.config/ai-agent-usage/secrets.conf, mode 600, NEVER sourced
#   3. Environment variable — deprecated fallback, emits a warning to stderr
#
# IMPORTANT: secrets.conf is parsed with grep/cut, never with `source`.
# Sourcing would export all vars into the shell environment where they are
# visible via /proc/PID/environ and inherited by every subshell.

SECRETS_FILE="${HOME}/.config/ai-agent-usage/secrets.conf"

# Validate secrets.conf: not a symlink, exists, has 600 permissions.
# Returns 0 on success, 1 on any violation (with message to stderr).
_check_secrets_file() {
    if [[ -L "$SECRETS_FILE" ]]; then
        echo "ERROR: secrets.conf is a symlink — refusing to read credentials" >&2
        return 1
    fi
    if [[ ! -f "$SECRETS_FILE" ]]; then
        return 1
    fi
    local perms
    if [[ "$(uname -s)" == "Darwin" ]]; then
        perms=$(stat -f "%OLp" "$SECRETS_FILE" 2>/dev/null)
    else
        perms=$(stat -c "%a" "$SECRETS_FILE" 2>/dev/null)
    fi
    if [[ "$perms" != "600" ]]; then
        echo "ERROR: secrets.conf has permissions $perms — must be 600." >&2
        echo "  Fix: chmod 600 $SECRETS_FILE" >&2
        return 1
    fi
}

# Read a credential from the OS keyring.
# Linux: secret-tool (GNOME Keyring / libsecret)
# macOS: security (Keychain)
# Outputs the value to stdout; returns 1 if keyring unavailable or key absent.
_read_keyring() {
    local key="$1"
    local os; os=$(uname -s)
    if [[ "$os" == "Linux" ]] && command -v secret-tool &>/dev/null; then
        secret-tool lookup service ai-agent-usage key "$key" 2>/dev/null
    elif [[ "$os" == "Darwin" ]] && command -v security &>/dev/null; then
        security find-generic-password -a "$key" -s ai-agent-usage -w 2>/dev/null
    else
        return 1
    fi
}

# Write a credential to the OS keyring.
# Returns 0 on success, 1 if keyring unavailable.
_write_keyring() {
    local key="$1" value="$2"
    local os; os=$(uname -s)
    if [[ "$os" == "Linux" ]] && command -v secret-tool &>/dev/null; then
        printf '%s' "$value" | secret-tool store \
            --label="ai-agent-usage: $key" \
            service ai-agent-usage key "$key" 2>/dev/null
    elif [[ "$os" == "Darwin" ]] && command -v security &>/dev/null; then
        # -U: update if exists
        security add-generic-password -U \
            -a "$key" -s ai-agent-usage -w "$value" 2>/dev/null
    else
        return 1
    fi
}

# Read a credential from secrets.conf.
# Parses with grep/cut — never sources the file.
_read_secrets_file() {
    local key="$1"
    _check_secrets_file || return 1
    local value
    # grep -m1: first match only. cut -d'=' -f2-: value may itself contain '='
    value=$(grep -m1 "^${key}=" "$SECRETS_FILE" 2>/dev/null | cut -d'=' -f2-)
    if [[ -n "$value" ]]; then
        printf '%s' "$value"
        return 0
    fi
    return 1
}

# Write or update a credential in secrets.conf.
# Atomically replaces the key's line; appends if the key is new.
_write_secrets_file() {
    local key="$1" value="$2"
    if [[ ! -f "$SECRETS_FILE" ]]; then
        (umask 177; touch "$SECRETS_FILE")  # mode 600
        printf '# ai-agent-usage secrets — do not chmod above 600\n' >> "$SECRETS_FILE"
        printf '# Format: KEY=value  (no shell syntax, no quotes, no export)\n' >> "$SECRETS_FILE"
    fi
    _check_secrets_file || return 1

    if grep -q "^${key}=" "$SECRETS_FILE" 2>/dev/null; then
        # Replace existing entry via a temp file (portable; avoids sed -i differences)
        local tmpfile; tmpfile=$(mktemp)
        grep -v "^${key}=" "$SECRETS_FILE" > "$tmpfile"
        printf '%s=%s\n' "$key" "$value" >> "$tmpfile"
        chmod 600 "$tmpfile"
        mv "$tmpfile" "$SECRETS_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$SECRETS_FILE"
    fi
}

# Read a credential securely.
#
# Usage (ALWAYS assign to a `local` variable):
#   local api_key
#   api_key=$(read_secret "ANTHROPIC_API_KEY") || { log ...; return 1; }
#   curl ... --config <(printf 'header = "Authorization: Bearer %s"\n' "$api_key")
#   unset api_key
#
# The key must never be exported or passed as a command-line argument.
read_secret() {
    local key="$1"
    local value

    # 1. OS keyring (most secure: encrypted at rest, memory-protected)
    value=$(_read_keyring "$key" 2>/dev/null)
    if [[ -n "$value" ]]; then
        printf '%s' "$value"
        return 0
    fi

    # 2. secrets.conf (600 perms, never sourced — no env leakage)
    value=$(_read_secrets_file "$key" 2>/dev/null)
    if [[ -n "$value" ]]; then
        printf '%s' "$value"
        return 0
    fi

    # 3. Environment variable — deprecated, leaks into /proc/PID/environ
    if [[ -n "${!key:-}" ]]; then
        echo "WARNING: $key read from environment variable." >&2
        echo "  Store it securely instead: ai-agent-usage set-key $key" >&2
        printf '%s' "${!key}"
        return 0
    fi

    return 1  # Not found anywhere
}

# Store a credential — tries keyring first, falls back to secrets.conf.
#
# Usage:
#   store_secret "ANTHROPIC_API_KEY" "$value"
store_secret() {
    local key="$1" value="$2"
    if _write_keyring "$key" "$value" 2>/dev/null; then
        echo "Stored $key in OS keyring (encrypted at rest)." >&2
    else
        _write_secrets_file "$key" "$value" || return 1
        echo "Stored $key in $SECRETS_FILE" >&2
        echo "  (OS keyring unavailable — file is mode 600)" >&2
    fi
}
