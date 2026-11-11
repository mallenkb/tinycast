#!/bin/bash
set -euo pipefail
revision=f3b407ca1bfeeecebf9e9ef19fcd6eed565bd70a
root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cache="$root/build/cleanup-runtime"
source="$cache/llama.cpp-$revision"
output="$cache/compiled-$revision-portable"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [[ ! -f "$source/CMakeLists.txt" ]]; then
    mkdir -p "$cache"
    curl --fail --location --silent --show-error "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$revision" -o "$cache/source.tar.gz"
    echo "2b90e0164fed14efee90335327f6975d0d4728d81761b2568ad367dbf59c9193  $cache/source.tar.gz" | shasum -a 256 -c -
    tar -xzf "$cache/source.tar.gz" -C "$cache"
fi
architectures="${ARCHS:-arm64}"
for architecture in $architectures; do
    build="$output-$architecture"
    cpu_options=(-DGGML_NATIVE=OFF)
    if [[ "$architecture" == arm64 ]]; then
        cpu_options+=(-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16)
    fi
    if [[ -x "$build/bin/llama-server" ]]; then continue; fi
    cmake -S "$source" -B "$build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        "${cpu_options[@]}" -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF \
        -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_BUILD_UI=OFF -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_SERVER=ON -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF \
        -DCMAKE_OSX_ARCHITECTURES="$architecture" -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
    cmake --build "$build" --target llama-server -j 4
done
if [[ -n "${TARGET_BUILD_DIR:-}" ]]; then
    destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/TinycastCleanup"
    mkdir -p "$(dirname "$destination")"
    binaries=()
    for architecture in $architectures; do
        binaries+=("$output-$architecture/bin/llama-server")
    done
    if (( ${#binaries[@]} == 1 )); then
        cp "${binaries[0]}" "$destination"
    else
        lipo -create "${binaries[@]}" -output "$destination"
    fi
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]]; then
        codesign --force --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$destination"
    fi
fi
