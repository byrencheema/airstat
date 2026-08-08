#!/bin/bash
# Signs, notarizes and packages AirStats as a .dmg users can download and open.
#
# Scripts/build.sh signs ad-hoc, which proves only that the bundle is intact. macOS
# refuses an ad-hoc bundle that arrived over the internet outright ("AirStats is
# damaged"), so distribution needs a real Developer ID signature, Apple's notarization
# ticket, and that ticket stapled onto the file so it validates with no network.
#
#   Scripts/release.sh          → .dmg in dist/
#
# Requires a Developer ID Application certificate in the keychain and a notarytool
# credential profile. Both are one-time setup; see the preflight errors below.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-AirStats}"
DIST="dist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="$DIST/AirStats-$VERSION.dmg"

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "error: no '$IDENTITY' certificate in the keychain." >&2
  echo "  Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "error: no notarytool credential profile named '$PROFILE'." >&2
  echo "  xcrun notarytool store-credentials $PROFILE \\" >&2
  echo "    --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <uuid>" >&2
  exit 1
fi

APP="$(Scripts/build.sh release | tail -n 1)"

# Extended attributes picked up from the filesystem (quarantine flags, Finder info)
# make codesign fail with a bare "resource fork, Finder information, or similar
# detritus not allowed" that names no file.
xattr -cr "$APP"

# --options runtime is the hardened runtime, which notarization refuses to accept
# without. --timestamp pins the signature to a trusted clock so it stays valid after
# the certificate itself expires.
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$APP"

codesign --verify --strict --deep "$APP"

# Notarize the app itself before packaging so the ticket can be stapled into the
# bundle. Stapling only the .dmg leaves the copy the user drags to /Applications
# without a ticket, and its first launch then needs a working network to verify.
ZIP="$DIST/AirStats-$VERSION-app.zip"
mkdir -p "$DIST"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

# A .dmg opens as a window holding the app next to a shortcut to /Applications, so
# installing is one drag. hdiutil builds it from a staging directory.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "AirStats" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# What Gatekeeper will decide on the user's machine. Anything but "accepted" here is
# what they would see instead of the app opening.
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "$DMG"
