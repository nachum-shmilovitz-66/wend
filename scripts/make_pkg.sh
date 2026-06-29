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

# postinstall: register the app, then launch it AFTER the installer quits. Launching
# during the install (as a child of Installer) makes macOS attribute Wend's Accessibility
# prompt to "Installer" and dismiss it when the installer closes. Waiting for Installer to
# exit, then opening from the user's launchd domain, gives the prompt Wend's own identity
# so it persists. Wend then pops the Accessibility prompt itself on first launch.
SCRIPTS="$WORK/scripts"
mkdir -p "$SCRIPTS"
cat > "$SCRIPTS/postinstall" <<'EOS'
#!/bin/bash
APP="/Applications/Wend.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1

loggedInUser=$(/usr/bin/stat -f %Su /dev/console)
uid=$(/usr/bin/id -u "$loggedInUser")
# Detached, in the user's GUI session: wait for Installer to quit, then open Wend.
/bin/launchctl asuser "$uid" /bin/bash -c '
  for i in $(seq 1 90); do /usr/bin/pgrep -x Installer >/dev/null || break; sleep 1; done
  sleep 1
  /usr/bin/open "'"$APP"'"
' >/dev/null 2>&1 &
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

# Closing screen: tell the user to open Wend and that it needs Accessibility.
RES="$WORK/resources"
mkdir -p "$RES"
cat > "$RES/conclusion.html" <<EOH
<!DOCTYPE html><html><body style="font-family:-apple-system,Helvetica;font-size:13px;margin:12px">
<b>$APP_NAME is installed.</b>
<p>$APP_NAME will <b>open automatically</b> in a moment and ask for <b>Accessibility</b> access.</p>
<p>In that prompt click <b>Open System Settings</b>, then switch on <b>$APP_NAME</b> in the
Accessibility list. You only do this once — it's required for $APP_NAME to read and fix your
selected text.</p>
<p>Then select wrong-layout text in any app and <b>double-tap Shift</b>. $APP_NAME also adds
itself to <b>Login Items</b>, so it starts at every login.</p>
<p>(If it doesn't open on its own, launch <b>$APP_NAME</b> from your Applications folder.)</p>
</body></html>
EOH

DIST_XML="$WORK/distribution.xml"
cat > "$DIST_XML" <<EOX
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>$APP_NAME by Shmilovitz ($VERSION)</title>
    <organization>$BUNDLE_ID</organization>
    <options customize="never" require-scripts="false"/>
    <welcome mime-type="text/plain">This installs $APP_NAME into your Applications folder.

When it finishes, $APP_NAME opens automatically and asks for Accessibility access — turn on $APP_NAME in the list. That's required for it to read and fix your selected text.</welcome>
    <conclusion file="conclusion.html" mime-type="text/html"/>
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
    productbuild --distribution "$DIST_XML" --package-path "$WORK" --resources "$RES" \
        --sign "$PKG_SIGN_IDENTITY" "$PKG" >/dev/null
else
    echo "==> Unsigned (set PKG_SIGN_IDENTITY=\"Developer ID Installer: ...\" to sign)"
    productbuild --distribution "$DIST_XML" --package-path "$WORK" --resources "$RES" "$PKG" >/dev/null
fi

echo "==> Done: $PKG"
ls -lh "$PKG"
