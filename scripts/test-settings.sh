#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-sources.sh
BUILD="${SINGULARITY_TEST_BUILD_DIR:-$PWD/.build}/settings-qa"
OUT="${1:-$BUILD/frames}"
QA="$BUILD/SettingsQA.app/Contents"
mkdir -p "$QA/MacOS" "$QA/Resources" "$OUT"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
bash scripts/build-physics.sh "$BUILD/physics"
cp Resources/AppIcon.icns singularity-codex-state "$QA/Resources/"
cat > "$QA/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.singularity.settings-qa</string><key>CFBundleExecutable</key><string>SettingsQA</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$(cat VERSION)</string></dict></plist>
PLIST
if ! xcrun swiftc -D SELF_TEST -swift-version 5 -target arm64-apple-macosx13.0 -import-objc-header PhysicsBridge.h \
  Tests/Settings/main.swift Tests/NativeSelfTest.swift "${APP_SOURCES[@]}" "$BUILD/physics/libSingularityPhysics.a" \
  -o "$QA/MacOS/SettingsQA" -framework Cocoa -framework SwiftUI -framework ScreenCaptureKit -framework OpenGL 2> "$BUILD/compile.log"; then
  cat "$BUILD/compile.log" >&2; exit 1
fi
"$QA/MacOS/SettingsQA" --self-test "$OUT"
