#!/usr/bin/env bash
# Build a .pkg installer that copies Wend.app to /Applications and launches it.
# Run scripts/package.sh first (ideally Developer ID signed) to produce the .app.
#
# Usage:
#   bash scripts/make_pkg.sh                                  # unsigned
#   PKG_SIGN_IDENTITY="Developer ID Installer: ... (TEAMID)" \
#     bash scripts/make_pkg.sh                                # signed (needs Installer cert)
#
# Output: dist/Wend-<version>.pkg
set -euo pipefail

APP_NAME="Wend"
BUNDLE_ID="${BUNDLE_ID:-com.nachumsh.wend}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

[ -d "$APP" ] || { echo "error: $APP not found — run scripts/package.sh first"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "1.0.0")"
PKG="$DIST/$APP_NAME-$VERSION.pkg"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Payload: /Applications/Wend.app
PAYLOAD="$WORK/payload"
mkdir -p "$PAYLOAD/Applications"
cp -R "$APP" "$PAYLOAD/Applications/"

# postinstall: launch Wend in the logged-in user's GUI session (scripts run as root).
SCRIPTS="$WORK/scripts"
mkdir -p "$SCRIPTS"
cat > "$SCRIPTS/postinstall" <<'EOS'
#!/bin/bash
# Runs as root during install. Launch Wend in the logged-in user's GUI session
# so they can grant Accessibility immediately. Logs to /tmp for diagnosis.
LOG="/tmp/wend-postinstall.log"
APP="/Applications/Wend.app"
loggedInUser=$(/usr/bin/stat -f %Su /dev/console)
uid=$(/usr/bin/id -u "$loggedInUser")
echo "$(date) postinstall: user=$loggedInUser uid=$uid app=$APP" >> "$LOG"

# Register the freshly-copied app with LaunchServices before opening it.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >> "$LOG" 2>&1

# Open in the user's session (not as root).
/bin/launchctl asuser "$uid" /usr/bin/open "$APP" >> "$LOG" 2>&1
echo "$(date) open exit=$?" >> "$LOG"
exit 0
EOS
chmod +x "$SCRIPTS/postinstall"

echo "==> Building component package"
COMPONENT="$WORK/$APP_NAME-component.pkg"

# Disable bundle relocation. By default pkgbuild marks .app bundles relocatable,
# so the Installer locates an existing copy (e.g. a dev build indexed by Spotlight)
# and installs OVER it instead of into /Applications. BundleIsRelocatable=false
# forces the install to the payload path.
COMPONENT_PLIST="$WORK/component.plist"
pkgbuild --analyze --root "$PAYLOAD" "$COMPONENT_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST" 2>/dev/null \
    || plutil -replace 0.BundleIsRelocatable -bool false "$COMPONENT_PLIST"

pkgbuild --root "$PAYLOAD" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "/" \
    --component-plist "$COMPONENT_PLIST" \
    --scripts "$SCRIPTS" \
    "$COMPONENT" >/dev/null

echo "==> Building product archive"
DIST_XML="$WORK/distribution.xml"
cat > "$DIST_XML" <<EOX
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>$APP_NAME by Shmilovitz ($VERSION)</title>
    <organization>$BUNDLE_ID</organization>
    <options customize="never" require-scripts="false"/>
    <welcome mime-type="text/plain">Installs $APP_NAME to your Applications folder and launches it.

After first launch, grant Accessibility access when prompted, then use it from the menu bar.</welcome>
    <choices-outline>
        <line choice="default"><line choice="$BUNDLE_ID"/></line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$BUNDLE_ID" visible="false">
        <pkg-ref id="$BUNDLE_ID"/>
    </choice>
    <pkg-ref id="$BUNDLE_ID" version="$VERSION" onConclusion="none">$APP_NAME-component.pkg</pkg-ref>
</installer-gui-script>
EOX

rm -f "$PKG"
if [ -n "${PKG_SIGN_IDENTITY:-}" ]; then
    echo "==> Signing product archive: $PKG_SIGN_IDENTITY"
    productbuild --distribution "$DIST_XML" --package-path "$WORK" \
        --sign "$PKG_SIGN_IDENTITY" "$PKG" >/dev/null
else
    echo "==> Unsigned (set PKG_SIGN_IDENTITY=\"Developer ID Installer: ...\" to sign)"
    productbuild --distribution "$DIST_XML" --package-path "$WORK" "$PKG" >/dev/null
fi

echo "==> Done: $PKG"
ls -lh "$PKG"
