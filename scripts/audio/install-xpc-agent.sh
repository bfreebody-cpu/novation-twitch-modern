#!/bin/sh
set -eu

label="com.twitchmodern.NovationTwitchModernAudioExperimental.bridge"
bundle="/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver"
expected_id="com.twitchmodern.NovationTwitchModernAudioExperimental"
source_plist="$bundle/Contents/Resources/$label.plist"
agent_dir="$HOME/Library/LaunchAgents"
agent_plist="$agent_dir/$label.plist"
log_dir="$HOME/Library/Logs/NovationTwitchModern"
domain="gui/$(id -u)"
staging="$agent_plist.pending.$$"
committed=0
agent_created=0

cleanup()
{
    rm -f -- "$staging"
    if [ "$committed" -eq 0 ] && [ "$agent_created" -eq 1 ]; then
        rm -f -- "$agent_plist"
    fi
}
trap cleanup EXIT INT TERM

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the logged-in user, without sudo." >&2
    exit 1
fi

test -d "$bundle" || {
    echo "Install the reviewed HAL bundle first: $bundle" >&2
    exit 1
}
actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$bundle/Contents/Info.plist")
test "$actual_id" = "$expected_id" || {
    echo "Refusing unexpected bundle identifier: $actual_id" >&2
    exit 1
}
test -f "$source_plist"
test -x "$bundle/Contents/Resources/TwitchAudioXPCService"
codesign --verify --deep --strict --verbose=2 "$bundle"

if [ -e "$agent_plist" ]; then
    echo "Refusing to replace existing path: $agent_plist" >&2
    exit 1
fi
if launchctl print "$domain/$label" >/dev/null 2>&1; then
    echo "Refusing because the service is already registered: $domain/$label" >&2
    exit 1
fi

mkdir -p "$agent_dir" "$log_dir"
install -m 0644 "$source_plist" "$staging"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string $log_dir/bridge.jsonl" \
    "$staging"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $log_dir/bridge.stderr" \
    "$staging"
plutil -lint "$staging"
mv "$staging" "$agent_plist"
agent_created=1
launchctl bootstrap "$domain" "$agent_plist"
committed=1

echo "Installed and registered exactly: $agent_plist"
echo "The helper remains on-demand and runs as the logged-in user."
echo "A normal reboot is required before installed Core Audio validation."
