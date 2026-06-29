#!/usr/bin/env bash
# Build a styled drag-to-Applications .dmg from dist/Wend.app.
# Compact window, custom background with an install arrow, fixed icon positions.
# Run scripts/package.sh first (ideally Developer ID signed) to produce the .app.
#
# Usage:  bash scripts/make_dmg.sh
# Output: dist/Wend-<version>.dmg  (version read from the app's Info.plist)

set -euo pipefail

APP_NAME="Wend"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

WIN_W=560; WIN_H=400; ICON_SIZE=104
WIN_X=320; WIN_Y=180   # top-left of window on screen

[ -d "$APP" ] || { echo "error: $APP not found — run scripts/package.sh first"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "1.0.0")"
VOL_NAME="$APP_NAME $VERSION"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; hdiutil detach "/Volumes/$VOL_NAME" -quiet 2>/dev/null || true' EXIT

# Detach any stale volume of the same name so the mount path is predictable.
hdiutil detach "/Volumes/$VOL_NAME" -quiet 2>/dev/null || true

echo "==> Rendering background"
swift "$ROOT/scripts/dmg_bg_render.swift" "$WORK/bg.png" >/dev/null

echo "==> Staging"
STAGING="$WORK/stage"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
cp "$WORK/bg.png" "$STAGING/.background/bg.png"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating writable image"
RW="$WORK/rw.dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDRW -ov "$RW" >/dev/null

echo "==> Mounting + styling window"
hdiutil attach "$RW" -nobrowse >/dev/null
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {$WIN_X, $WIN_Y, $((WIN_X + WIN_W)), $((WIN_Y + WIN_H))}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to $ICON_SIZE
    set text size of vo to 13
    set background picture of vo to file ".background:bg.png"
    set position of item "$APP_NAME.app" of container window to {150, 170}
    set position of item "Applications" of container window to {410, 170}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
sync

echo "==> Finalizing compressed image"
hdiutil detach "/Volumes/$VOL_NAME" -quiet
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null && echo "==> Verified OK"
echo "==> Done: $DMG"
ls -lh "$DMG"
