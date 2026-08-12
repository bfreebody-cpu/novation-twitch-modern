#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir="$repo_dir/.build/audio-hal-probe"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
capture_dir="$repo_dir/captures/audio/phase2-rate-change-$stamp"
name="/ntm_rate_$$"
helper_pid=""

cleanup()
{
    if [ -n "$helper_pid" ] && kill -0 "$helper_pid" 2>/dev/null; then
        kill "$helper_pid" 2>/dev/null || true
        wait "$helper_pid" 2>/dev/null || true
    fi
    "$build_dir/TwitchAudioDiscardHelper" --name "$name" --cleanup \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

mkdir -p "$capture_dir"
"$build_dir/TwitchAudioDiscardHelper" \
    --name "$name" --duration 7 --verify-pattern --report-ms 500 \
    >"$capture_dir/helper.jsonl" 2>"$capture_dir/helper.stderr" &
helper_pid=$!
sleep 0.1

"$build_dir/SharedAudioSyntheticProducer" \
    --name "$name" --duration 3 --rate 48000 \
    >"$capture_dir/producer-48000.jsonl" \
    2>"$capture_dir/producer-48000.stderr"
"$build_dir/SharedAudioSyntheticProducer" \
    --name "$name" --duration 3 --rate 44100 \
    >"$capture_dir/producer-44100.jsonl" \
    2>"$capture_dir/producer-44100.stderr"
wait "$helper_pid"
helper_pid=""

summary=$(tail -n 1 "$capture_dir/helper.jsonl")
printf '%s\n' "$summary"
printf '%s\n' "$summary" | grep -q '"rate":44100'
printf '%s\n' "$summary" | grep -q '"producer_generation":2'
printf '%s\n' "$summary" | grep -q '"fill_frames":0'
printf '%s\n' "$summary" | grep -q '"dropped_frames":0'
printf '%s\n' "$summary" | grep -q '"overruns":0'
printf '%s\n' "$summary" | grep -q '"pattern_errors":0'
printf '%s\n' "$summary" | grep -q '"non_finite_samples":0'

echo "PASS: continuous helper observed 48 kHz to 44.1 kHz producer change"
echo "Capture: $capture_dir"
