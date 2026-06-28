#!/usr/bin/env bash
# Build KeyLayoutFix and assemble a .app bundle. Optionally code-signs with the hardened
# runtime if a signing identity is provided (required before notarization).
#
# Usage:
#   bash scripts/package.sh                 # build + bundle only (unsigned)
#   SIGN_IDENTITY="Developer ID Application: Nachum Shmilovitz (96Y4LX7FVB)" \
#     bash scripts/package.sh               # build + bundle + sign (hardened runtime)
#
# Env overrides:
#   BUNDLE_ID       default com.nachumsh.keylayoutfix
#   SHORT_VERSION   default 1.0
#   BUILD_VERSION   default 1
#   SIGN_IDENTITY   Developer ID Application identity (omit to skip signing)

set -euo pipefail

APP_NAME="KeyLayoutFix"
BUNDLE_ID="${BUNDLE_ID:-com.nachumsh.keylayoutfix}"
SHORT_VERSION="${SHORT_VERSION:-1.0}"
BUILD_VERSION="${BUILD_VERSION:-1}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building release binary"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$APP_NAME"
[ -f "$BIN" ] || { echo "error: built binary not found at $BIN"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Info.plist with placeholders filled in.
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    -e "s/__SHORT_VERSION__/$SHORT_VERSION/" \
    -e "s/__BUILD_VERSION__/$BUILD_VERSION/" \
    "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"

# PkgInfo (harmless, conventional).
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> Signing with hardened runtime: $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$APP"
    echo "==> Verifying signature"
    codesign --verify --strict --verbose=2 "$APP"
else
    echo "==> Skipping signing (set SIGN_IDENTITY to sign). App is unsigned."
fi

echo "==> Done: $APP"
