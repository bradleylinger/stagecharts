#!/bin/bash
# Builds, signs (Developer ID), notarizes and publishes a Mac release with a Sparkle update feed.
#   tools/release-mac.sh 1.0.1 "What's new in this version"
# One-time setup:
#   xcrun notarytool store-credentials stagecharts-notary --apple-id <you> --team-id 7XA8LJU26H
#   (Sparkle signing key lives in the login keychain, account "stagecharts")
set -euo pipefail
VERSION="${1:?usage: release-mac.sh <version> [notes]}"
NOTES="${2:-StageCharts $VERSION}"
cd "$(dirname "$0")/.."
REPO=interactivesupply/stagecharts
BUILD=$(git rev-list --count HEAD)
OUT=.build/release/$VERSION
FEED=.build/release/appcast
SPARKLE=.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin
rm -rf "$OUT"; mkdir -p "$OUT" "$FEED"

echo "▸ Archive $VERSION ($BUILD)"
xcodegen generate >/dev/null
xcodebuild archive -project StageCharts.xcodeproj -scheme StageCharts -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$OUT/StageCharts.xcarchive" \
  -derivedDataPath .build/xcode \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=7XA8LJU26H \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp -quiet

echo "▸ Export (Developer ID)"
xcodebuild -exportArchive -archivePath "$OUT/StageCharts.xcarchive" \
  -exportOptionsPlist tools/ExportOptions-mac.plist -exportPath "$OUT/export" -quiet
APP="$OUT/export/StageCharts.app"

echo "▸ Notarize"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile stagecharts-notary --wait
xcrun stapler staple "$APP"
spctl -a -vv "$APP"

echo "▸ Package"
ZIP="StageCharts-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$FEED/$ZIP"
hdiutil create -volname "StageCharts" -srcfolder "$APP" -ov -format UDZO "$OUT/StageCharts-$VERSION.dmg" >/dev/null

echo "▸ Appcast"
"$SPARKLE/generate_appcast" --account stagecharts \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" "$FEED"

echo "▸ Publish GitHub release v$VERSION"
gh release create "v$VERSION" "$FEED/$ZIP" "$OUT/StageCharts-$VERSION.dmg" "$FEED/appcast.xml" \
  --repo "$REPO" --title "StageCharts $VERSION" --notes "$NOTES"
echo "✓ Released https://github.com/$REPO/releases/tag/v$VERSION"
