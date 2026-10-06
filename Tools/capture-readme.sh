#!/bin/zsh
set -euo pipefail
GALPI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$GALPI_ROOT"
mkdir -p work docs/images
GALPI_CAPTURE_ROOT="$(mktemp -d "$GALPI_ROOT/work/readme-capture.XXXXXX")"
GALPI_CAPTURE_APP="$GALPI_CAPTURE_ROOT/GalpiDocs.app"
# Use the real app UI with separate preferences, example data, and no account access.
mkdir -p "$GALPI_CAPTURE_APP/Contents/MacOS" "$GALPI_CAPTURE_APP/Contents/Resources" "$GALPI_CAPTURE_ROOT/data"
npm run web
swiftc -swift-version 5 -D UITEST -target "$(uname -m)-apple-macos13.0" Sources/*.swift Tools/CaptureReadme.swift -o "$GALPI_CAPTURE_APP/Contents/MacOS/Galpi" -framework AppKit -framework WebKit -framework AVFoundation -framework ScreenCaptureKit -framework Speech -framework Carbon -framework Security -framework Network -framework CryptoKit
cp Resources/Info.plist "$GALPI_CAPTURE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.galpi.documentation' "$GALPI_CAPTURE_APP/Contents/Info.plist"
cp Resources/index.html Resources/app.css Resources/app.js "$GALPI_CAPTURE_APP/Contents/Resources/"
codesign --force --sign - --options runtime --entitlements Resources/Galpi.entitlements "$GALPI_CAPTURE_APP"
GALPI_UI_TEST=1 GALPI_DATA_DIR="$GALPI_CAPTURE_ROOT/data" "$GALPI_CAPTURE_APP/Contents/MacOS/Galpi" "$GALPI_ROOT/docs/images"
iconutil -c iconset Resources/Galpi.icns -o "$GALPI_CAPTURE_ROOT/Galpi.iconset"
cp "$GALPI_CAPTURE_ROOT/Galpi.iconset/icon_256x256@2x.png" docs/images/app-icon.png
printf 'README images saved in %s/docs/images\n' "$GALPI_ROOT"
