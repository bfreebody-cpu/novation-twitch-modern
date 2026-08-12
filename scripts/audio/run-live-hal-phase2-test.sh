#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir="$repo_dir/.build/audio-hal-probe"
install_path="/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver"
expected_id="com.twitchmodern.NovationTwitchModernAudioExperimental"
duration=${1:-5}
rate=${2:-48000}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
capture_dir="$repo_dir/captures/audio/phase2-live-$stamp-${rate}hz"
helper_pid=""

cleanup()
{
    if [ -n "$helper_pid" ] && kill -0 "$helper_pid" 2>/dev/null; then
        kill "$helper_pid" 2>/dev/null || true
        wait "$helper_pid" 2>/dev/null || true
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

test -d "$install_path" || {
    echo "Phase 2 HAL bundle is not installed. Stop and follow the reviewed install contract." >&2
    exit 1
}
actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$install_path/Contents/Info.plist")
test "$actual_id" = "$expected_id"
test -x "$build_dir/TwitchAudioDiscardHelper"
test -x "$build_dir/HalLiveProbe"
mkdir -p "$capture_dir"

helper_duration=$(awk -v value="$duration" 'BEGIN { printf "%.3f", value + 1.0 }')
"$build_dir/TwitchAudioDiscardHelper" \
    --duration "$helper_duration" --report-ms 1000 \
    >"$capture_dir/helper.jsonl" 2>"$capture_dir/helper.stderr" &
helper_pid=$!
sleep 0.25

"$build_dir/HalLiveProbe" --duration "$duration" --rate "$rate" \
    >"$capture_dir/hal.log" 2>"$capture_dir/hal.stderr"
wait "$helper_pid"
helper_pid=""

summary=$(tail -n 1 "$capture_dir/helper.jsonl")
printf '%s\n' "$summary"
cat "$capture_dir/hal.log"
printf '%s\n' "$summary" | grep -q '"fill_frames":0'
printf '%s\n' "$summary" | grep -q '"dropped_frames":0'
printf '%s\n' "$summary" | grep -q '"overruns":0'
printf '%s\n' "$summary" | grep -q '"pattern_errors":0'
printf '%s\n' "$summary" | grep -q '"non_finite_samples":0'

echo "PASS: installed HAL to independent helper (${duration}s at ${rate} Hz)"
echo "Capture: $capture_dir"
