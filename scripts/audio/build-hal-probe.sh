#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
source_dir="$repo_dir/audio/hal-plugin"
build_dir="$repo_dir/.build/audio-hal-probe"

if ! command -v cmake >/dev/null 2>&1; then
    echo "CMake is required. Install it with: brew install cmake" >&2
    exit 1
fi

cmake -S "$source_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCODESIGN_ID=-
cmake --build "$build_dir" --parallel
ctest --test-dir "$build_dir" --output-on-failure

bundle="$build_dir/NovationTwitchModernAudioExperimental.driver"
test -d "$bundle"

echo "Built: $bundle"
codesign --verify --deep --strict --verbose=2 "$bundle"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$bundle/Contents/Info.plist"
