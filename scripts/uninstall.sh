#!/usr/bin/env bash
# Uninstall Wend: quit it, remove the app, drop the installer receipt and user data.
# macOS .pkg installers can't uninstall themselves, so this script does it.
#
# Tip: toggle "Launch at Login" OFF in Wend's menu BEFORE running this, so the
# login-item registration is cleaned up by the app. Otherwise remove a lingering
# entry from System Settings > General > Login Items afterwards.
#
# Usage:  bash scripts/uninstall.sh
set -euo pipefail

APP="/Applications/Wend.app"
BUNDLE_ID="com.nachumsh.wend"

echo "==> Quitting Wend"
osascript -e 'tell application "Wend" to quit' 2>/dev/null || true
pkill -x Wend 2>/dev/null || true
sleep 1

if [ -d "$APP" ]; then
    echo "==> Removing $APP (needs admin)"
    sudo rm -rf "$APP"
else
    echo "==> $APP not present"
fi

echo "==> Forgetting installer receipt"
sudo pkgutil --forget "$BUNDLE_ID" 2>/dev/null || true

echo "==> Removing user data"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -f "$HOME/Library/Logs/Wend.log"

echo "==> Done. If 'Wend' still appears in System Settings > General > Login Items, remove it there."
