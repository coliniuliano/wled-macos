#!/bin/bash
# Build WLED.app without Xcode: swiftc -> hand-assembled bundle -> ad-hoc sign.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/WLED.app"
NAME="WLED"
MIN_OS="14.0"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling"
swiftc \
  -target "${ARCH}-apple-macos${MIN_OS}" \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -o "$APP/Contents/MacOS/$NAME" \
  Sources/*.swift

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc signing"
codesign --force --sign - --identifier "local.wled.menubar" "$APP"

echo "==> built $APP"
