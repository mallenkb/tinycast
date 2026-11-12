#!/bin/bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
    run|--build-only|--debug|--logs|--telemetry|--verify) ;;
    *)
        echo "Usage: $0 [--build-only|--debug|--logs|--telemetry|--verify]" >&2
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

BUILD_LOG=$(mktemp -t tinycast-dev-build)
trap 'rm -f "$BUILD_LOG"' EXIT
retry_deadline=$((SECONDS + 120))
waiting_for_build=0
echo "Building $APP_NAME..."
while true; do
    if xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug \
        -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED" \
        -quiet build >"$BUILD_LOG" 2>&1; then
        cat "$BUILD_LOG"
        break
    else
        build_status=$?
    fi
    if (( SECONDS >= retry_deadline )) || ! grep -Fq 'unable to attach DB:' "$BUILD_LOG" \
        || ! grep -Fq 'database is locked' "$BUILD_LOG"; then
        cat "$BUILD_LOG" >&2
        exit "$build_status"
    fi
    if (( ! waiting_for_build )); then
        echo "Waiting for the other Xcode build to release the database..."
        waiting_for_build=1
    fi
    sleep 2
done

if [[ "$MODE" == --build-only ]]; then
    echo "Build complete."
    exit 0
fi

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
