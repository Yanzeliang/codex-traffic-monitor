#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
UID_VALUE="$(id -u)"
DOMAIN="gui/${UID_VALUE}"
APP_TARGET="$HOME/Applications/Codex Monitor.app"
DATA_TARGET="$HOME/.local/share/codex-traffic-monitor"
AGENTS="$HOME/Library/LaunchAgents"

"${ROOT}/scripts/build_macos_app.sh"
mkdir -p "$HOME/Applications" "${DATA_TARGET}" "${AGENTS}"
ditto "${ROOT}/build/Codex Monitor.app" "${APP_TARGET}"
xattr -cr "${APP_TARGET}"
codesign --force --deep --sign - "${APP_TARGET}"
codesign --verify --deep --strict "${APP_TARGET}"
cp "${ROOT}/scripts/codex_monitor.py" "${DATA_TARGET}/codex_monitor.py"
chmod 700 "${DATA_TARGET}/codex_monitor.py"
cp "${ROOT}/macos-widget/com.local.codex-traffic-monitor.plist" "${AGENTS}/com.local.codex-traffic-monitor.plist"
cp "${ROOT}/macos-widget/com.local.codex-traffic-widget.plist" "${AGENTS}/com.local.codex-traffic-widget.plist"

launchctl bootout "${DOMAIN}" "${AGENTS}/com.local.codex-traffic-monitor.plist" 2>/dev/null || true
launchctl bootout "${DOMAIN}" "${AGENTS}/com.local.codex-traffic-widget.plist" 2>/dev/null || true
launchctl bootstrap "${DOMAIN}" "${AGENTS}/com.local.codex-traffic-monitor.plist"
launchctl bootstrap "${DOMAIN}" "${AGENTS}/com.local.codex-traffic-widget.plist"

echo "Codex Traffic Monitor is running from the macOS menu bar."
