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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

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

# Sparkle is a framework, and the binary asks for it at @rpath. SwiftPM leaves a copy
# beside the binary, which is why the bare `.build/debug/AirStats` runs; the bundle
# needs its own, because the executable inside it resolves @rpath through
# @executable_path/../Frameworks (see Package.swift).
#
# ditto rather than cp -R: a framework is a tree of symlinks into Versions/, and the
# ones that go missing here are the ones codesign refuses to sign later.
SPARKLE="$BIN_DIR/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
else
  echo "error: $SPARKLE is missing; the app would not launch" >&2
  exit 1
fi

# Sparkle writes "1.2 is now available—you have 1.1", and nothing else this app puts on
# screen uses an em dash. Only the English values are rewritten: the keys are what the
# framework looks strings up by, so changing one loses the translation entirely, and the
# other languages are somebody else's prose. Patched here rather than upstream because
# Scripts/release.sh signs the framework after this runs, so the signature covers it.
python3 - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Base.lproj/Sparkle.strings" <<'PY'
import plistlib, sys

path = sys.argv[1]
with open(path, 'rb') as handle:
    strings = plistlib.load(handle)

patched = {key: value.replace('available—you have', 'available, you have')
           for key, value in strings.items()}
if patched != strings:
    with open(path, 'wb') as handle:
        plistlib.dump(patched, handle, fmt=plistlib.FMT_BINARY)
PY

# Ad-hoc signature. Without any signature macOS refuses some window-server
# privileges a status item needs.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
  echo "warning: codesign failed; the app may still run" >&2
}

echo "$APP"
