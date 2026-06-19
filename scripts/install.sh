#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_TARGET="$HOME/Applications/Codex Monitor.app"
DOMAIN="gui/$(id -u)"
AGENTS="$HOME/Library/LaunchAgents"

for label in com.local.codex-traffic-monitor com.local.codex-traffic-widget; do
  launchctl bootout "${DOMAIN}" "${AGENTS}/${label}.plist" 2>/dev/null || true
done
rm -f "${AGENTS}/com.local.codex-traffic-monitor.plist" "${AGENTS}/com.local.codex-traffic-widget.plist"

"${ROOT}/scripts/build_macos_app.sh"
mkdir -p "$HOME/Applications"
ditto "${ROOT}/build/Codex Monitor.app" "${APP_TARGET}"
xattr -cr "${APP_TARGET}"
codesign --force --deep --sign - "${APP_TARGET}"
codesign --verify --deep --strict "${APP_TARGET}"

echo "Installed ${APP_TARGET}. Open it manually when monitoring is needed."
