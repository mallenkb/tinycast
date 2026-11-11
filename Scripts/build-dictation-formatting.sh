#!/bin/bash
set -euo pipefail

version=v0.3.3
digest=bc80d3044237536218e81268abea7372a7fe547a0390760353c92ee27c156ee3
root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cache="$root/build/dictation-formatting"
archive="$cache/$version.zip"
library="$cache/$version-phrases.dylib"
mkdir -p "$cache"

if [[ ! -f "$library" ]]; then
    work="$(mktemp -d "$cache/build.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    if [[ ! -f "$archive" ]]; then
        curl --fail --location --silent --show-error --retry 2 \
            "https://github.com/FluidInference/text-processing-rs/releases/download/$version/NemoTextProcessing.xcframework.zip" \
            -o "$work/source.zip"
        printf '%s  %s\n' "$digest" "$work/source.zip" | shasum -a 256 -c -
        mv "$work/source.zip" "$archive"
    fi
    printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c -
    unzip -p "$archive" \
        NemoTextProcessing.xcframework/macos-arm64_x86_64/libtext_processing_rs.a > "$work/runtime.a"
    xcrun clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 \
        -install_name @rpath/TinycastTextFormatting.dylib -Wl,-dead_strip \
        -Wl,-u,_nemo_normalize -Wl,-exported_symbol,_nemo_normalize \
        -Wl,-u,_nemo_free_string -Wl,-exported_symbol,_nemo_free_string \
        "$work/runtime.a" -o "$work/runtime.dylib"
    mv "$work/runtime.dylib" "$library"
fi

if [[ -n "${TARGET_BUILD_DIR:-}" ]]; then
    destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/TinycastTextFormatting.dylib"
    mkdir -p "$(dirname "$destination")"
    cp "$library" "$destination"
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]]; then
        codesign --force --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$destination"
    fi
fi
