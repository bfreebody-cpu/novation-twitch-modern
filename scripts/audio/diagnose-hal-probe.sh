#!/bin/sh
set -eu

install_path="/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver"

echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "Architecture: $(uname -m)"
if [ -d "$install_path" ]; then
    echo "Installed bundle: $install_path"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$install_path/Contents/Info.plist"
    codesign -dvv "$install_path" 2>&1
    codesign --verify --deep --strict --verbose=2 "$install_path"
else
    echo "Experimental bundle is not installed."
fi

echo "Matching Core Audio registry entry, if present:"
system_profiler SPAudioDataType 2>/dev/null | \
    grep -A12 -B2 'Novation Twitch Modern Audio - Experimental' || true
