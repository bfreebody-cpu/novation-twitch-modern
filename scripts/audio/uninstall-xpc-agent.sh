#!/bin/sh
set -eu

label="com.twitchmodern.NovationTwitchModernAudioExperimental.bridge"
agent_plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the logged-in user, without sudo." >&2
    exit 1
fi

if launchctl print "$domain/$label" >/dev/null 2>&1; then
    launchctl bootout "$domain/$label"
fi

if [ ! -e "$agent_plist" ]; then
    echo "No user LaunchAgent installed at: $agent_plist"
else
    actual_label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$agent_plist")
    test "$actual_label" = "$label" || {
        echo "Refusing to remove unexpected LaunchAgent label: $actual_label" >&2
        exit 1
    }
    rm -f -- "$agent_plist"
    echo "Removed exactly: $agent_plist"
fi

echo "The project log directory is deliberately preserved as test evidence."
