#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DEST="${1:-dist}"
mkdir -p "$DEST/奇点.app/Contents/MacOS" "$DEST/奇点.app/Contents/Resources"
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  SWIFT=(env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc)
else
  SWIFT=(swiftc)
fi
"${SWIFT[@]}" -swift-version 5 -O -target arm64-apple-macosx13.0 main.swift Behavior.swift CodexState.swift -o "$DEST/奇点.app/Contents/MacOS/Singularity" -framework Cocoa -framework SwiftUI -framework ScreenCaptureKit -framework OpenGL 2> build.log
cp Resources/* "$DEST/奇点.app/Contents/Resources/"
cat > "$DEST/奇点.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Singularity</string><key>CFBundleIdentifier</key><string>local.singularity.pet</string><key>CFBundleName</key><string>奇点</string><key>CFBundleDisplayName</key><string>奇点</string><key>CFBundleVersion</key><string>4</string><key>CFBundleShortVersionString</key><string>1.2</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/><key>CFBundleIconFile</key><string>AppIcon</string><key>NSScreenCaptureUsageDescription</key><string>奇点需要读取屏幕画面，以实时扭曲黑洞背后的桌面内容。画面仅在本机用于渲染，不录制或上传。</string></dict></plist>
PLIST
codesign --force --deep --sign - "$DEST/奇点.app"
