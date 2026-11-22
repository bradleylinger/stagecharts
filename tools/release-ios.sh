#!/bin/bash
# Build StageCharts for iPad/iPhone and upload it to App Store Connect (TestFlight).
# Usage: tools/release-ios.sh <version>        e.g. tools/release-ios.sh 1.0.3
# Uses the Apple account signed in to Xcode. The build appears in TestFlight after Apple processes it.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version, e.g. 1.0.3}"
BUILD="$(git rev-list --count HEAD)"
OUT=".build/release-ios/$VERSION-$BUILD"
rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate >/dev/null
echo "== Archiving $VERSION ($BUILD)"
xcodebuild -project StageCharts.xcodeproj -scheme StageCharts -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/StageCharts.xcarchive" \
  -allowProvisioningUpdates MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive | tail -3
echo "== Uploading to App Store Connect"
xcodebuild -exportArchive -archivePath "$OUT/StageCharts.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist tools/ExportOptions-ios.plist -allowProvisioningUpdates | tail -5
echo "✓ Uploaded $VERSION ($BUILD). It shows up in TestFlight after Apple finishes processing (usually 5–20 min)."
