#!/usr/bin/env bash
# Notarize and staple a SIGNED Wend.app (run scripts/package.sh with SIGN_IDENTITY first).
#
# One-time credential setup (stores an app-specific password in the keychain):
#   1. Create an app-specific password at https://account.apple.com (Sign-In & Security).
#   2. xcrun notarytool store-credentials "KLF-notary" \
#        --apple-id "you@example.com" \
#        --team-id 96Y4LX7FVB \
#        --password "abcd-efgh-ijkl-mnop"
#
# Then:
#   bash scripts/notarize.sh
#
# Env overrides:
#   NOTARY_PROFILE  keychain profile name (default KLF-notary)

set -euo pipefail

APP_NAME="Wend"
NOTARY_PROFILE="${NOTARY_PROFILE:-KLF-notary}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME.zip"

[ -d "$APP" ] || { echo "error: $APP not found — run scripts/package.sh with SIGN_IDENTITY first"; exit 1; }

echo "==> Verifying the app is signed with a hardened runtime"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Zipping for submission"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (waits for result)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket to the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Notarized: $APP"
