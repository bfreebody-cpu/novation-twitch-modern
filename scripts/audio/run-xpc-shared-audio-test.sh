#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir="$repo_dir/.build/audio-hal-probe"
plist="$build_dir/xpc-local-test.plist"
label="com.twitchmodern.NovationTwitchModernAudioExperimental.bridge"
domain="gui/$(id -u)"
duration=${1:-5}
rate=${2:-48000}
stdout_path="$build_dir/xpc-service.stdout"
stderr_path="$build_dir/xpc-service.stderr"
loaded=0

cleanup()
{
    if [ "$loaded" -eq 1 ]; then
        launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

case "$duration" in
    ''|*[!0-9.]*) echo "duration must be a positive number of seconds" >&2; exit 2 ;;
esac
case "$rate" in
    44100|48000) ;;
    *) echo "rate must be 44100 or 48000" >&2; exit 2 ;;
esac

test -x "$build_dir/TwitchAudioXPCService"
test -x "$build_dir/XPCSyntheticProducer"
test -f "$plist"

if launchctl print "$domain/$label" >/dev/null 2>&1; then
    echo "Refusing to replace an already loaded XPC service: $domain/$label" >&2
    exit 1
fi

: >"$stdout_path"
: >"$stderr_path"
launchctl bootstrap "$domain" "$plist"
loaded=1

"$build_dir/XPCSyntheticProducer" "$duration" "$rate"

# Give the consumer one reporting interval to drain the final callback.
sleep 0.4
launchctl bootout "$domain/$label"
loaded=0

summary=$(tail -n 1 "$stdout_path")
printf '%s\n' "$summary"
printf '%s\n' "$summary" | grep -q '"pattern_errors":0'
printf '%s\n' "$summary" | grep -q '"non_finite_samples":0'
printf '%s\n' "$summary" | grep -q '"overruns":0'
printf '%s\n' "$summary" | grep -q '"accepted_peers":1'
test ! -s "$stderr_path"

printf '%s\n' "$summary" | grep -q '"rate":'"$rate"

echo "PASS: launchd XPC shared-memory handoff (${duration}s at ${rate} Hz)"
