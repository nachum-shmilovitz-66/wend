#!/usr/bin/env bash
# Render the Wend app icon and build Packaging/Wend.icns.
# Regenerate whenever scripts/icon_render.swift changes.
#   bash scripts/make_icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGING="$ROOT/Packaging"
ICNS="$PACKAGING/Wend.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Rendering master 1024×1024 PNG"
MASTER="$WORK/icon_1024.png"
swift "$ROOT/scripts/icon_render.swift" "$MASTER" >/dev/null

echo "==> Building iconset"
SET="$WORK/Wend.iconset"
mkdir -p "$SET"
# (size, filename) pairs required by iconutil
for spec in \
    "16:icon_16x16.png" "32:icon_16x16@2x.png" \
    "32:icon_32x32.png" "64:icon_32x32@2x.png" \
    "128:icon_128x128.png" "256:icon_128x128@2x.png" \
    "256:icon_256x256.png" "512:icon_256x256@2x.png" \
    "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" "$MASTER" --out "$SET/$name" >/dev/null
done

echo "==> Packing .icns"
mkdir -p "$PACKAGING"
iconutil -c icns "$SET" -o "$ICNS"
echo "==> Done: $ICNS"
ls -lh "$ICNS"
