#!/bin/zsh
set -euo pipefail
GALPI_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$GALPI_ROOT"
GALPI_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
GALPI_IDENTITY="${GALPI_SIGN_IDENTITY:--}"
GALPI_PROFILE="${GALPI_NOTARY_PROFILE:-}"
GALPI_RELEASE_KIND="beta"
if [[ -n "$GALPI_PROFILE" && "$GALPI_IDENTITY" == - ]]; then
  echo 'Notarization requires GALPI_SIGN_IDENTITY with a Developer ID Application certificate.' >&2; exit 1
fi
GALPI_APP_PATH="$GALPI_ROOT/build/Release/Galpi.app" GALPI_ARCHS="arm64 x86_64" ./build.sh
GALPI_APP="$GALPI_ROOT/build/Release/Galpi.app"
mkdir -p "$GALPI_ROOT/dist"
GALPI_STAGE="$(mktemp -d "$GALPI_ROOT/build/release.XXXXXX")"
trap 'rm -rf "$GALPI_STAGE"' EXIT
GALPI_NOTARIZED=false
if [[ "$GALPI_IDENTITY" != - ]]; then
  codesign -dvv "$GALPI_APP" 2> "$GALPI_STAGE/signing.txt"
  if ! rg -q '^Authority=Developer ID Application:' "$GALPI_STAGE/signing.txt"; then
    echo 'Public distribution requires Developer ID Application, not Apple Development.' >&2; exit 1
  fi
  GALPI_RELEASE_KIND="signed-unnotarized"
fi
notarize() {
  local GALPI_INPUT="$1" GALPI_LOG="$2"
  xcrun notarytool submit "$GALPI_INPUT" --keychain-profile "$GALPI_PROFILE" --wait --timeout 20m --output-format json > "$GALPI_LOG"
  /usr/bin/plutil -extract status raw "$GALPI_LOG" | /usr/bin/grep -qx Accepted || { cat "$GALPI_LOG" >&2; return 1; }
}
if [[ -n "$GALPI_PROFILE" ]]; then
  ditto -c -k --keepParent "$GALPI_APP" "$GALPI_STAGE/notarize.zip"
  notarize "$GALPI_STAGE/notarize.zip" "$GALPI_ROOT/dist/notary-app-$GALPI_VERSION.json"
  xcrun stapler staple "$GALPI_APP"
  xcrun stapler validate "$GALPI_APP"
  GALPI_NOTARIZED=true;GALPI_RELEASE_KIND="release"
fi
GALPI_NAME="Galpi-$GALPI_VERSION-universal-$GALPI_RELEASE_KIND"
GALPI_DEST="$GALPI_ROOT/dist/$GALPI_NAME"
mkdir -p "$GALPI_STAGE/disk"
ditto "$GALPI_APP" "$GALPI_STAGE/disk/Galpi.app"
ln -s /Applications "$GALPI_STAGE/disk/Applications"
cp INSTALL.txt "$GALPI_STAGE/disk/설치 안내.txt"
hdiutil create -quiet -volname "Galpi $GALPI_VERSION" -srcfolder "$GALPI_STAGE/disk" -format UDZO -fs HFS+ "$GALPI_STAGE/$GALPI_NAME.dmg"
if [[ "$GALPI_IDENTITY" != - ]]; then
  codesign --sign "$GALPI_IDENTITY" --timestamp "$GALPI_STAGE/$GALPI_NAME.dmg"
fi
if [[ "$GALPI_NOTARIZED" == true ]]; then
  notarize "$GALPI_STAGE/$GALPI_NAME.dmg" "$GALPI_ROOT/dist/notary-dmg-$GALPI_VERSION.json"
  xcrun stapler staple "$GALPI_STAGE/$GALPI_NAME.dmg"
  xcrun stapler validate "$GALPI_STAGE/$GALPI_NAME.dmg"
  spctl --assess --type execute --verbose=2 "$GALPI_APP"
fi
ditto -c -k --keepParent "$GALPI_APP" "$GALPI_STAGE/$GALPI_NAME.zip"
# Source allowlist deliberately excludes data, credentials, dependencies and build intermediates.
mkdir -p "$GALPI_STAGE/source/Galpi"
for GALPI_FILE in Sources Web Resources Tools Tests docs build.sh release.sh test-ui.sh README.md INSTALL.txt THIRD_PARTY_NOTICES.txt package.json package-lock.json .gitignore; do
  ditto "$GALPI_FILE" "$GALPI_STAGE/source/Galpi/$GALPI_FILE"
done
ditto -c -k --keepParent "$GALPI_STAGE/source/Galpi" "$GALPI_STAGE/Galpi-$GALPI_VERSION-source.zip"
mv "$GALPI_STAGE/$GALPI_NAME.dmg" "$GALPI_DEST.dmg"
mv "$GALPI_STAGE/$GALPI_NAME.zip" "$GALPI_DEST.zip"
mv "$GALPI_STAGE/Galpi-$GALPI_VERSION-source.zip" "$GALPI_ROOT/dist/Galpi-$GALPI_VERSION-source.zip"
cat > "$GALPI_DEST.json" <<JSON
{
  "version": "$GALPI_VERSION",
  "minimumMacOS": "13.0",
  "architectures": ["arm64", "x86_64"],
  "kind": "$GALPI_RELEASE_KIND",
  "notarized": $GALPI_NOTARIZED,
  "hardwareTested": "Apple Silicon on macOS 26.3.1",
  "olderHardwareTested": false
}
JSON
(cd "$GALPI_ROOT/dist" && shasum -a 256 "$GALPI_NAME.dmg" "$GALPI_NAME.zip" "Galpi-$GALPI_VERSION-source.zip" > "$GALPI_NAME-SHA256SUMS.txt")
hdiutil verify "$GALPI_DEST.dmg"
echo "Release files: $GALPI_DEST.{dmg,zip,json}"
echo "Notarized: $GALPI_NOTARIZED"
