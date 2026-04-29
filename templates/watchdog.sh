#!/bin/bash
set -uo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
eval "$(~/.local/bin/mise activate bash 2>/dev/null)" || true

LOG="$HOME/.openclaw/logs/watchdog.log"
TS=$(date +"%Y-%m-%dT%H:%M:%S%z")

if openclaw gateway status >/dev/null 2>&1; then
    exit 0
fi

echo "$TS [WARN] gateway not responding; kicking LaunchAgent" >> "$LOG"
launchctl kickstart -k "gui/$UID/ai.openclaw.gateway" >> "$LOG" 2>&1
