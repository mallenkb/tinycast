#!/bin/bash
# Build a signed universal DMG and updater ZIP. Usage: build-dmg.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
IDENTITY="${TINYCAST_SIGNING_IDENTITY:-Tinycast Self-Signed}"
ARCHITECTURES="${TINYCAST_ARCHS:-arm64 x86_64}"
SIGNING_FLAGS="--timestamp=none"
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
    SIGNING_FLAGS="--timestamp"
fi
DERIVED="build/DerivedData"

if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "✗ '$IDENTITY' code-signing identity not found — create it once (docs/signing.md)." >&2
    exit 1
fi

echo "▸ Building signed Tinycast.app (Release)…"
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="$SIGNING_FLAGS" \
    ARCHS="$ARCHITECTURES" ONLY_ACTIVE_ARCH=NO \
    ${1:+MARKETING_VERSION="$1"} \
    build

APP="$DERIVED/Build/Products/Release/Tinycast.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PACKAGE="Tinycast-${VERSION}"
if [[ "$ARCHITECTURES" == *" "* ]]; then
    PACKAGE="Tinycast-Universal-${VERSION}"
fi
DMG="build/${PACKAGE}.dmg"

echo "▸ Packaging ${DMG}"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
diskutil image create from "$STAGE" --format UDZO --volumeName "Tinycast" "$DMG" >/dev/null
rm -rf "$STAGE"

ditto -c -k --keepParent --sequesterRsrc "$APP" "build/${PACKAGE}.zip"
echo "✓ $DMG and build/${PACKAGE}.zip"