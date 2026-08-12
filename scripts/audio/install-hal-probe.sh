#!/bin/sh
set -eu

expected_id="com.twitchmodern.NovationTwitchModernAudioExperimental"
install_path="/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver"
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
bundle="$repo_dir/.build/audio-hal-probe/NovationTwitchModernAudioExperimental.driver"

if [ "$(id -u)" -ne 0 ]; then
    echo "Administrator authorization is required." >&2
    echo "After reviewing audio/INSTALLATION_CONTRACT.md, run:" >&2
    printf '  sudo "%s"\n' "$0" >&2
    exit 1
fi

test -d "$bundle" || {
    echo "Build artifact not found: $bundle" >&2
    exit 1
}

actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$bundle/Contents/Info.plist")
test "$actual_id" = "$expected_id" || {
    echo "Refusing unexpected bundle identifier: $actual_id" >&2
    exit 1
}

if [ -e "$install_path" ]; then
    echo "Refusing to replace existing path: $install_path" >&2
    exit 1
fi

echo "Installing exactly: $install_path"
ditto "$bundle" "$install_path"
chown -R root:wheel "$install_path"
codesign --verify --deep --strict --verbose=2 "$install_path"
echo "Installed successfully. A normal reboot is required before Core Audio"
echo "can discover the plug-in. After reboot, open Audio MIDI Setup and look for:"
echo "  Novation Twitch Modern Audio - Experimental"
echo "Before reboot, return to the logged-in shell and install the user XPC agent:"
printf '  "%s/scripts/audio/install-xpc-agent.sh"\n' "$repo_dir"
