#!/bin/zsh
set -euo pipefail

UID_VALUE="$(id -u)"
DOMAIN="gui/${UID_VALUE}"
AGENTS="$HOME/Library/LaunchAgents"

for label in com.local.codex-traffic-monitor com.local.codex-traffic-widget; do
  launchctl bootout "${DOMAIN}" "${AGENTS}/${label}.plist" 2>/dev/null || true
done

rm -f "${AGENTS}/com.local.codex-traffic-monitor.plist" "${AGENTS}/com.local.codex-traffic-widget.plist"
rm -rf "$HOME/Applications/Codex Monitor.app"
echo "App and legacy background services removed. Data remains in ~/.codex-monitor."
