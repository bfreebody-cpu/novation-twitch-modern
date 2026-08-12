#!/bin/sh
set -eu

expected_id="com.twitchmodern.NovationTwitchModernAudioExperimental"
install_path="/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver"

if [ "$(id -u)" -ne 0 ]; then
    echo "Administrator authorization is required." >&2
    printf 'Run: sudo "%s"\n' "$0" >&2
    exit 1
fi

if [ ! -e "$install_path" ]; then
    echo "Nothing installed at: $install_path"
else
    actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$install_path/Contents/Info.plist")
    test "$actual_id" = "$expected_id" || {
        echo "Refusing to remove unexpected bundle identifier: $actual_id" >&2
        exit 1
    }

    echo "Removing exactly: $install_path"
    rm -rf -- "$install_path"
fi

echo "The required reboot clears the Phase 2 shared-memory runtime state."
echo "The root uninstaller deliberately does not execute build-tree helpers."
echo "Removed experimental HAL probe. Reboot normally to complete removal."
