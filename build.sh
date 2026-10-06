#!/bin/zsh
set -euo pipefail
GALPI_ROOT="$(cd "$(dirname "$0")" && pwd)"
GALPI_APP="${GALPI_APP_PATH:-$GALPI_ROOT/build/Release/Galpi.app}"
GALPI_ARCHS="${GALPI_ARCHS:-arm64 x86_64}"
GALPI_IDENTITY="${GALPI_SIGN_IDENTITY:--}"
cd "$GALPI_ROOT"
if [[ ! -d node_modules ]]; then npm ci --no-audit --no-fund; fi
npm run web
mkdir -p build
GALPI_STAGE="$(mktemp -d "$GALPI_ROOT/build/stage.XXXXXX")"
trap 'rm -rf "$GALPI_STAGE"' EXIT
GALPI_BUNDLE="$GALPI_STAGE/Galpi.app"
mkdir -p "$GALPI_BUNDLE/Contents/MacOS" "$GALPI_BUNDLE/Contents/Resources"
GALPI_MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
typeset -a GALPI_BINARIES
for GALPI_ARCH in ${=GALPI_ARCHS}; do
  [[ "$GALPI_ARCH" == arm64 || "$GALPI_ARCH" == x86_64 ]] || { echo "Unsupported architecture: $GALPI_ARCH" >&2; exit 1; }
  echo "Compiling $GALPI_ARCH for macOS $GALPI_MIN_OS+"
  xcrun swiftc -swift-version 5 -O -whole-module-optimization -target "$GALPI_ARCH-apple-macos$GALPI_MIN_OS" Sources/*.swift -o "$GALPI_STAGE/Galpi-$GALPI_ARCH" -framework AppKit -framework WebKit -framework AVFoundation -framework ScreenCaptureKit -framework Speech -framework Carbon -framework Security -framework Network -framework CryptoKit
  GALPI_BINARIES+=("$GALPI_STAGE/Galpi-$GALPI_ARCH")
done
xcrun lipo -create "${GALPI_BINARIES[@]}" -output "$GALPI_BUNDLE/Contents/MacOS/Galpi"
cp Resources/Info.plist "$GALPI_BUNDLE/Contents/Info.plist"
cp Resources/index.html Resources/app.css Resources/app.js Resources/Galpi.icns THIRD_PARTY_NOTICES.txt "$GALPI_BUNDLE/Contents/Resources/"
if [[ "$GALPI_IDENTITY" == - ]]; then
  codesign --force --sign - --options runtime --timestamp=none --entitlements Resources/Galpi.entitlements "$GALPI_BUNDLE"
else
  codesign --force --sign "$GALPI_IDENTITY" --options runtime --timestamp --entitlements Resources/Galpi.entitlements "$GALPI_BUNDLE"
fi
codesign --verify --strict --verbose=2 "$GALPI_BUNDLE"
mkdir -p "$(dirname "$GALPI_APP")"
# Only replace an app at the explicitly selected build output.
[[ "$GALPI_APP" == *.app ]] || { echo 'GALPI_APP_PATH must end with .app' >&2; exit 1; }
if [[ -e "$GALPI_APP" ]]; then
  [[ -f "$GALPI_APP/Contents/Info.plist" ]] || { echo 'Output is not an app bundle' >&2; exit 1; }
  rm -rf "$GALPI_APP"
fi
mv "$GALPI_BUNDLE" "$GALPI_APP"
echo "Built: $GALPI_APP"
xcrun lipo -archs "$GALPI_APP/Contents/MacOS/Galpi"
