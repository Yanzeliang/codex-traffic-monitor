#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_DIR="${ROOT}/build"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/codex-traffic-monitor-build.XXXXXX")"
APP="${STAGE}/Codex Monitor.app"
CACHE="${TMPDIR:-/tmp}/codex-traffic-monitor-module-cache"
trap 'rm -rf "${STAGE}"' EXIT

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${CACHE}"
export CLANG_MODULE_CACHE_PATH="${CACHE}"

xcrun swiftc -parse-as-library -O \
  -framework SwiftUI -framework AppKit \
  -o "${APP}/Contents/MacOS/CodexMonitorWidget" \
  "${ROOT}/macos-widget/CodexMonitorWidget.swift"

cp "${ROOT}/macos-widget/Info.plist" "${APP}/Contents/Info.plist"
cp "${ROOT}/assets/CodexMonitor.icns" "${APP}/Contents/Resources/CodexMonitor.icns"
cp "${ROOT}/scripts/codex_monitor.py" "${APP}/Contents/Resources/codex_monitor.py"
chmod 700 "${APP}/Contents/Resources/codex_monitor.py"
xattr -cr "${APP}"
codesign --force --deep --sign - "${APP}"
codesign --verify --deep --strict "${APP}"
mkdir -p "${BUILD_DIR}"
rm -rf "${BUILD_DIR}/Codex Monitor.app"
ditto "${APP}" "${BUILD_DIR}/Codex Monitor.app"
echo "Built ${BUILD_DIR}/Codex Monitor.app"
