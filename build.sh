#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DEST="${1:-dist}"
VERSION="$(cat VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION: $VERSION" >&2; exit 1; }
source scripts/swift-sources.sh
mkdir -p "$DEST/奇点.app/Contents/MacOS" "$DEST/奇点.app/Contents/Resources"
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  SWIFT=(env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc)
else
  SWIFT=(swiftc)
fi
bash scripts/build-physics.sh
"${SWIFT[@]}" -swift-version 5 -O -target arm64-apple-macosx13.0 -import-objc-header PhysicsBridge.h main.swift "${APP_SOURCES[@]}" .build/physics/libSingularityPhysics.a -o "$DEST/奇点.app/Contents/MacOS/Singularity" -framework Cocoa -framework SwiftUI -framework ScreenCaptureKit -framework OpenGL 2>&1 | tee build.log
cp Resources/* singularity-codex-state "$DEST/奇点.app/Contents/Resources/"
cp Vendor/Chipmunk2D/LICENSE.txt "$DEST/奇点.app/Contents/Resources/Chipmunk2D-LICENSE.txt"
cat > "$DEST/奇点.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Singularity</string><key>CFBundleIdentifier</key><string>local.singularity.pet</string><key>CFBundleName</key><string>奇点</string><key>CFBundleDisplayName</key><string>奇点</string><key>CFBundleVersion</key><string>17</string><key>CFBundleShortVersionString</key><string>$VERSION</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/><key>CFBundleIconFile</key><string>AppIcon</string><key>NSScreenCaptureUsageDescription</key><string>奇点需要读取屏幕画面，以实时扭曲黑洞背后的桌面内容。画面仅在本机用于渲染，不录制或上传。</string></dict></plist>
PLIST
SIGNING_IDENTITY="${SINGULARITY_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"$/\1/p' | head -n 1 || true)"
fi
if [ -n "$SIGNING_IDENTITY" ]; then
  echo "Signing with Apple Development identity: $SIGNING_IDENTITY"
  codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$DEST/奇点.app"
else
  echo "No Apple Development identity found; falling back to ad-hoc signing"
  codesign --force --options runtime --sign - "$DEST/奇点.app"
fi
