#!/bin/bash
# Assemble .build/KillSwitchBar.app from the release binary (ad-hoc signed).
#   scripts/build-app.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/KillSwitchBar.app"
ID="io.github.vladsidorovich.vpn-killswitch.bar"

cd "$ROOT"
swift build -c release --product KillSwitchBar
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/KillSwitchBar "$APP/Contents/MacOS/KillSwitchBar"
cp packaging/KillSwitchBar-Info.plist "$APP/Contents/Info.plist"
[ -f assets/AppIcon.icns ] || scripts/make-icons.sh
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier "$ID" "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
