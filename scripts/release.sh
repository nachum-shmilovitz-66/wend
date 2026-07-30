#!/usr/bin/env bash
# One-shot signed + notarized release build. Refuses to emit an unsigned / un-notarized
# artifact, so a release can't accidentally ship without Developer ID signing + notarization
# (see WND-13 and the "signed + notarized every release" rule).
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Nachum Shmilovitz (96Y4LX7FVB)" \
#   PKG_SIGN_IDENTITY="Developer ID Installer: Nachum Shmilovitz (96Y4LX7FVB)" \
#     bash scripts/release.sh
#
# Env overrides: NOTARY_PROFILE (default KLF-notary).
#
# Output: dist/Wend-<version>.pkg (signed, notarized, stapled) + a notarized dist/Wend.app.
set -euo pipefail

: "${SIGN_IDENTITY:?refusing to build an unsigned release — set SIGN_IDENTITY (Developer ID Application)}"
: "${PKG_SIGN_IDENTITY:?refusing to build an unsigned installer — set PKG_SIGN_IDENTITY (Developer ID Installer)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-KLF-notary}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Wend.app"

echo "==> 1/4 Building + signing the app"
SIGN_IDENTITY="$SIGN_IDENTITY" bash "$ROOT/scripts/package.sh"

echo "==> 2/4 Notarizing + stapling the app"
NOTARY_PROFILE="$NOTARY_PROFILE" bash "$ROOT/scripts/notarize.sh"

echo "==> 3/4 Building the signed installer"
PKG_SIGN_IDENTITY="$PKG_SIGN_IDENTITY" bash "$ROOT/scripts/make_pkg.sh"

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
PKG="$ROOT/dist/Wend-$VERSION.pkg"

echo "==> 4/4 Notarizing + stapling the installer"
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait

# Stapling a .pkg intermittently fails with "the written data did not validate" (error 73)
# even after the notary service accepted the submission; retrying succeeds. Retry rather
# than abort, so a transient failure doesn't cost a full rebuild + resubmission.
for attempt in 1 2 3; do
    if xcrun stapler staple "$PKG"; then break; fi
    [ "$attempt" = 3 ] && { echo "error: stapling failed after 3 attempts"; exit 1; }
    echo "==> Staple attempt $attempt failed; retrying in 15s"
    sleep 15
done

xcrun stapler validate "$PKG"
spctl --assess --type install --verbose=2 "$PKG"

# Prune superseded installers. Only runs once the new .pkg is signed, notarized and
# stapled above, so a failed build never deletes the last good artifact. Keeping older
# .pkg files around invites installing the wrong one by accident when testing.
shopt -s nullglob
for old in "$ROOT"/dist/Wend-*.pkg; do
    [ "$old" = "$PKG" ] && continue
    echo "==> Removing superseded installer: $(basename "$old")"
    rm -f "$old"
done
shopt -u nullglob

echo "==> Release artifact ready (signed + notarized): $PKG"
