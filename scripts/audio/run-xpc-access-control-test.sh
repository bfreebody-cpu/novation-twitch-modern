#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir="$repo_dir/.build/audio-hal-probe"
plist="$build_dir/xpc-local-rejection-test.plist"
label="com.twitchmodern.NovationTwitchModernAudioExperimental.bridge"
domain="gui/$(id -u)"
loaded=0

cleanup()
{
    if [ "$loaded" -eq 1 ]; then
        launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

if launchctl print "$domain/$label" >/dev/null 2>&1; then
    echo "Refusing to replace an already loaded XPC service: $domain/$label" >&2
    exit 1
fi

: >"$build_dir/xpc-rejection.stdout"
: >"$build_dir/xpc-rejection.stderr"
launchctl bootstrap "$domain" "$plist"
loaded=1

set +e
result=$("$build_dir/XPCSyntheticProducer" 1 48000 2>&1)
status=$?
set -e

test "$status" -ne 0
printf '%s\n' "$result" | grep -q '^XPC connection failed:'
sleep 0.1
grep -q '"event":"ready"' "$build_dir/xpc-rejection.stdout"
grep -q '"allowed_euid":4294967294' "$build_dir/xpc-rejection.stdout"

echo "PASS: XPC service rejected a client whose EUID was not authorized"
