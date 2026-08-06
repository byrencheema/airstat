#!/bin/bash
# Builds AirStats and assembles a launchable .app bundle.
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
APP="$BIN_DIR/AirStats.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/AirStats" "$APP/Contents/MacOS/AirStats"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM emits the UI target's resources as a bundle beside the binary. It has to
# travel into Contents/Resources or `Bundle.module` finds nothing at runtime and the
# app launches without its own mark.
#
# Named exactly rather than globbed: a tree built under an earlier package name leaves
# that name's bundle in the bin directory forever, and a glob ships both.
BUNDLE="$BIN_DIR/AirStats_AirStatUI.bundle"
if [ -d "$BUNDLE" ]; then
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
else
  echo "error: $BUNDLE is missing; the app would launch with no logo" >&2
  exit 1
fi

# Ad-hoc signature. Without any signature macOS refuses some window-server
# privileges a status item needs.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
  echo "warning: codesign failed; the app may still run" >&2
}

echo "$APP"
