#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/奇点.app/Contents/Info.plist)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/singularity-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto dist/奇点.app "$STAGE/奇点.app"
ln -s /Applications "$STAGE/Applications"
cp README.md "$STAGE/README.md"
hdiutil create -volname "奇点 Singularity $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/Singularity-$VERSION-AppleSilicon.dmg"
ditto -c -k --sequesterRsrc --keepParent dist/奇点.app "dist/Singularity-$VERSION-AppleSilicon.zip"
codesign --verify --deep --strict dist/奇点.app
hdiutil verify "dist/Singularity-$VERSION-AppleSilicon.dmg"
shasum -a 256 dist/*.dmg dist/*.zip > dist/SHA256SUMS.txt
