#!/bin/bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
    run|--debug|--logs|--telemetry|--verify) ;;
    *)
        echo "Usage: $0 [--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac

cd "$(dirname "$0")/.." || exit 1
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_NAME="Tinycast Dev"
BUNDLE_ID="com.tinycast.app.dev"
DERIVED="build/DerivedData"
APP_BUNDLE="$PWD/$DERIVED/Build/Products/Debug/$APP_NAME.app"

if ! security find-identity -p codesigning | grep -q 'Tinycast Self-Signed'; then
    echo "Create the Tinycast Self-Signed signing identity first. See docs/signing.md." >&2
    exit 1
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

echo "Building $APP_NAME..."
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED" \
    -quiet build

echo "Build complete. Launching $APP_NAME..."
case "$MODE" in
    run)
        /usr/bin/open -n "$APP_BUNDLE"
        ;;
    --debug)
        xcrun lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
        ;;
    --logs)
        /usr/bin/open -n "$APP_BUNDLE"
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry)
        /usr/bin/open -n "$APP_BUNDLE"
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify)
        /usr/bin/open -n "$APP_BUNDLE"
        for ((attempt = 0; attempt < 20; attempt++)); do
            if pgrep -x "$APP_NAME" >/dev/null; then
                echo "$APP_NAME is running."
                exit 0
            fi
            sleep 0.25
        done
        echo "$APP_NAME did not start." >&2
        exit 1
        ;;
esac
