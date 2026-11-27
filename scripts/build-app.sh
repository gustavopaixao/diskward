#!/usr/bin/env bash
# Builds build/Diskward.app from the Swift package.
#
#   scripts/build-app.sh              # release build, ad-hoc signed
#   SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" scripts/build-app.sh
#
# Full Disk Access is tied to the code signature. With ad-hoc signing (the default)
# macOS may forget the permission after every rebuild. Use a stable identity
# (`security find-identity -v -p codesigning`) to avoid that.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Diskward.app"
swift build -c release --product StorageHelper
BIN="$(swift build -c release --show-bin-path)/StorageHelper"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StorageHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Asset catalog → Assets.car (menu bar glyph, accent color) + AppIcon.icns.
# SwiftPM can't compile asset catalogs for executables, so we run Xcode's actool directly.
xcrun actool Resources/Assets.xcassets \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --accent-color AccentColor \
    --output-partial-info-plist build/assetcatalog_info.plist \
    --errors --warnings --notices \
    --output-format human-readable-text

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
echo "Run:      open \"$APP\""
echo "Install:  cp -R \"$APP\" /Applications/"
