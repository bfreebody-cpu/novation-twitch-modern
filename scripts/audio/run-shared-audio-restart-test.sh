#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir="$repo_dir/.build/audio-hal-probe"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
capture_dir="$repo_dir/captures/audio/phase2-restart-$stamp"
name="/ntm_restart_$$"
producer_pid=""
helper_pid=""

cleanup()
{
    for process_id in "$helper_pid" "$producer_pid"; do
        if [ -n "$process_id" ] && kill -0 "$process_id" 2>/dev/null; then
            kill "$process_id" 2>/dev/null || true
            wait "$process_id" 2>/dev/null || true
        fi
    done
    "$build_dir/TwitchAudioDiscardHelper" --name "$name" --cleanup \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

mkdir -p "$capture_dir"
"$build_dir/TwitchAudioDiscardHelper" --name "$name" --cleanup >/dev/null

# Deliberately exercise producer-before-helper. The ring safely holds this
# bounded backlog; ConsumerStart discards it because delayed audio is stale.
"$build_dir/SharedAudioSyntheticProducer" \
    --name "$name" --duration 7 --rate 48000 \
    >"$capture_dir/producer.jsonl" 2>"$capture_dir/producer.stderr" &
producer_pid=$!
sleep 0.5

"$build_dir/TwitchAudioDiscardHelper" \
    --name "$name" --duration 10 --verify-pattern --report-ms 500 \
    >"$capture_dir/helper-1.jsonl" 2>"$capture_dir/helper-1.stderr" &
helper_pid=$!
sleep 0.25
if "$build_dir/TwitchAudioDiscardHelper" \
    --name "$name" --duration 0.1 \
    >"$capture_dir/helper-contender.log" \
    2>"$capture_dir/helper-contender.stderr"; then
    echo "FAIL: a second live helper acquired the consumer role" >&2
    exit 1
fi
grep -q 'another live helper already owns' \
    "$capture_dir/helper-contender.stderr"
sleep 1.75
kill -9 "$helper_pid"
wait "$helper_pid" 2>/dev/null || true
helper_pid=""

# Leave the helper unavailable beyond the one-second stale-owner threshold,
# then prove a new process can claim the abandoned consumer generation,
# discard stale backlog, and resume without resetting the producer.
sleep 1.1
"$build_dir/TwitchAudioDiscardHelper" \
    --name "$name" --duration 2.5 --verify-pattern --report-ms 500 \
    >"$capture_dir/helper-2.jsonl" 2>"$capture_dir/helper-2.stderr" &
helper_pid=$!
wait "$producer_pid"
producer_pid=""
wait "$helper_pid"
helper_pid=""

first_summary=$(tail -n 1 "$capture_dir/helper-1.jsonl")
second_summary=$(tail -n 1 "$capture_dir/helper-2.jsonl")
producer_summary=$(tail -n 1 "$capture_dir/producer.jsonl")
printf '%s\n%s\n%s\n' "$first_summary" "$second_summary" "$producer_summary"

printf '%s\n' "$first_summary" | grep -q '"pattern_errors":0'
printf '%s\n' "$second_summary" | grep -q '"pattern_errors":0'
printf '%s\n' "$second_summary" | grep -q '"consumer_generation":2'
discarded=$(printf '%s\n' "$second_summary" | \
    sed -E 's/.*"stale_frames_discarded":([0-9]+).*/\1/')
test "$discarded" -gt 0
printf '%s\n' "$producer_summary" | grep -q '"overruns":0'

echo "PASS: helper absence, attach, exit, restart, and stale-data handling"
echo "Capture: $capture_dir"
