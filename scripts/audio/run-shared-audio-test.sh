#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir="$repo_dir/.build/audio-hal-probe"
duration=${1:-10}
rate=${2:-48000}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
capture_dir="$repo_dir/captures/audio/phase2-$stamp-${rate}hz"
name="/ntm_test_$$"
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

case "$duration" in
    ''|*[!0-9.]*) echo "duration must be a positive number of seconds" >&2; exit 2 ;;
esac
case "$rate" in
    44100|48000) ;;
    *) echo "rate must be 44100 or 48000" >&2; exit 2 ;;
esac

test -x "$build_dir/TwitchAudioDiscardHelper"
test -x "$build_dir/SharedAudioSyntheticProducer"
mkdir -p "$capture_dir"

helper_duration=$(awk -v value="$duration" 'BEGIN { printf "%.3f", value + 1.0 }')
"$build_dir/TwitchAudioDiscardHelper" \
    --name "$name" \
    --duration "$helper_duration" \
    --report-ms 1000 \
    --verify-pattern \
    >"$capture_dir/helper.jsonl" 2>"$capture_dir/helper.stderr" &
helper_pid=$!

# Deliberately exercise helper-before-producer ordering.
sleep 0.1
"$build_dir/SharedAudioSyntheticProducer" \
    --name "$name" \
    --duration "$duration" \
    --rate "$rate" \
    >"$capture_dir/producer.jsonl" 2>"$capture_dir/producer.stderr"
wait "$helper_pid"
helper_pid=""

summary=$(tail -n 1 "$capture_dir/helper.jsonl")
producer_summary=$(tail -n 1 "$capture_dir/producer.jsonl")
printf '%s\n' "$summary"
printf '%s\n' "$producer_summary"

printf '%s\n' "$summary" | grep -q '"pattern_errors":0'
printf '%s\n' "$summary" | grep -q '"non_finite_samples":0'
printf '%s\n' "$summary" | grep -q '"overruns":0'
printf '%s\n' "$producer_summary" | grep -q '"overruns":0'

echo "PASS: two-process shared-audio test (${duration}s at ${rate} Hz)"
echo "Capture: $capture_dir"
