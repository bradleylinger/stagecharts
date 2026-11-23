#!/bin/bash
# Downloads Ableton's LinkKit (Link for iOS) into Vendor/LinkKit. Needed for iPhone/iPad builds.
# LinkKit is licensed by Ableton (Vendor/LinkKit/LICENSE.md) and must not be committed or redistributed.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-LinkKit-4.1.3}"
tmp=$(mktemp -d)
gh release download "$VERSION" -R Ableton/LinkKit -p LinkKit.zip -D "$tmp"
unzip -q "$tmp/LinkKit.zip" -d "$tmp/x"
rm -rf Vendor/LinkKit && mkdir -p Vendor/LinkKit
mv "$tmp/x/LinkKit.xcframework" "$tmp/x/LinkKitResources.bundle" "$tmp/x/LICENSE.md" "$tmp/x/Ableton_Link_UI_Guidelines.pdf" Vendor/LinkKit/
rm -rf "$tmp"
echo "✓ $VERSION in Vendor/LinkKit"
