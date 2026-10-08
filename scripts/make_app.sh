#!/bin/zsh
# 构建 FileMerge.app（SwiftPM 产物 → 应用包）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product FileMergeApp

APP="build/FileMerge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/FileMergeApp "$APP/Contents/MacOS/FileMergeApp"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "已生成 $APP"
