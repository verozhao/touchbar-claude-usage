#!/bin/bash
# Builds ClaudeTouchBar.app with plain swiftc (no Xcode needed, Command Line Tools are enough).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/ClaudeTouchBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/"
swiftc -O \
  -import-objc-header Sources/Private.h \
  -F /System/Library/PrivateFrameworks \
  -framework AppKit -framework DFRFoundation \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/ClaudeTouchBar"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
