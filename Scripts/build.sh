#!/bin/bash
# Builds AirStat and assembles a launchable .app bundle.
#
# SwiftPM cannot produce an app bundle, and a menu bar app needs one: LSUIElement,
# a bundle identifier for UserDefaults and notifications, and a code signature so
# macOS will grant it a status item. So we build the binary and wrap it here.
#
#   Scripts/build.sh            → debug build
#   Scripts/build.sh release    → optimised build
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"

swift build -c "$CONFIG" "${@:2}"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$BIN_DIR/AirStat.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/AirStat" "$APP/Contents/MacOS/AirStat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature. Without any signature macOS refuses some window-server
# privileges a status item needs.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
  echo "warning: codesign failed; the app may still run" >&2
}

echo "$APP"
