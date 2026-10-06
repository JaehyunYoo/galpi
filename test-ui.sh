#!/bin/zsh
set -euo pipefail
GALPI_ROOT="$(cd "$(dirname "$0")" && pwd)"
GALPI_TEST_ROOT="${GALPI_TEST_ROOT:?Set GALPI_TEST_ROOT to a scratch directory}"
GALPI_TEST_ROOT="$GALPI_TEST_ROOT/run-$(uuidgen)"
GALPI_TEST_APP="$GALPI_TEST_ROOT/GalpiUITest.app"
cd "$GALPI_ROOT"
mkdir -p "$GALPI_TEST_APP/Contents/MacOS" "$GALPI_TEST_APP/Contents/Resources" "$GALPI_TEST_ROOT/data"
swiftc -swift-version 5 -D UITEST -target "$(uname -m)-apple-macos13.0" Sources/*.swift Tests/UITest.swift -o "$GALPI_TEST_APP/Contents/MacOS/Galpi" -framework AppKit -framework WebKit -framework AVFoundation -framework ScreenCaptureKit -framework Speech -framework Carbon -framework Security -framework Network -framework CryptoKit
cp Resources/Info.plist "$GALPI_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.galpi.ui-test' "$GALPI_TEST_APP/Contents/Info.plist"
cp Resources/index.html Resources/app.css Resources/app.js "$GALPI_TEST_APP/Contents/Resources/"
codesign --force --sign - --options runtime --entitlements Resources/Galpi.entitlements "$GALPI_TEST_APP"
GALPI_UI_TEST=1 GALPI_DATA_DIR="$GALPI_TEST_ROOT/data" "$GALPI_TEST_APP/Contents/MacOS/Galpi" "$GALPI_ROOT/Tests/ui.js"
