#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir="$repo_dir/.build/audio-hal-probe"
install_path="/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver"
expected_id="com.twitchmodern.NovationTwitchModernAudioExperimental"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
capture_dir="$repo_dir/captures/audio/phase2-live-restart-$stamp"
hal_pid=""
helper_pid=""

cleanup()
{
    for process_id in "$helper_pid" "$hal_pid"; do
        if [ -n "$process_id" ] && kill -0 "$process_id" 2>/dev/null; then
            kill "$process_id" 2>/dev/null || true
            wait "$process_id" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT INT TERM

test -d "$install_path" || {
    echo "Phase 2 HAL bundle is not installed. Stop and follow the reviewed install contract." >&2
    exit 1
}
actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$install_path/Contents/Info.plist")
test "$actual_id" = "$expected_id"
test -x "$build_dir/HalLiveProbe"
test -x "$build_dir/TwitchAudioDiscardHelper"
mkdir -p "$capture_dir"

"$build_dir/HalLiveProbe" --duration 7 --rate 48000 \
    >"$capture_dir/hal.log" 2>"$capture_dir/hal.stderr" &
hal_pid=$!
sleep 0.5

"$build_dir/TwitchAudioDiscardHelper" --duration 10 --report-ms 500 \
    >"$capture_dir/helper-1.jsonl" 2>"$capture_dir/helper-1.stderr" &
helper_pid=$!
sleep 2
kill -9 "$helper_pid"
wait "$helper_pid" 2>/dev/null || true
helper_pid=""

sleep 1.1
"$build_dir/TwitchAudioDiscardHelper" --duration 2.5 --report-ms 500 \
    >"$capture_dir/helper-2.jsonl" 2>"$capture_dir/helper-2.stderr" &
helper_pid=$!
wait "$hal_pid"
hal_pid=""
wait "$helper_pid"
helper_pid=""

first_status=$(tail -n 1 "$capture_dir/helper-1.jsonl")
second_summary=$(tail -n 1 "$capture_dir/helper-2.jsonl")
printf '%s\n%s\n' "$first_status" "$second_summary"
cat "$capture_dir/hal.log"
printf '%s\n' "$second_summary" | grep -q '"consumer_generation":2'
printf '%s\n' "$second_summary" | grep -q '"dropped_frames":0'
printf '%s\n' "$second_summary" | grep -q '"overruns":0'
printf '%s\n' "$second_summary" | grep -q '"non_finite_samples":0'

echo "PASS: live HAL continued across abrupt helper exit and restart"
echo "Capture: $capture_dir"
