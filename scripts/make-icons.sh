#!/bin/bash
# Build assets/AppIcon.icns from the CoreGraphics rendering of the app icon.
# Needs: swift, sips, iconutil (all in the Command Line Tools / macOS).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SET="$TMP/AppIcon.iconset"; mkdir "$SET"

swift "$ROOT/scripts/render-icon.swift" "$TMP/icon1024.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$TMP/icon1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/assets/AppIcon.icns"
cp "$TMP/icon1024.png" "$ROOT/assets/AppIcon.png"
echo "wrote assets/AppIcon.icns and assets/AppIcon.png"
