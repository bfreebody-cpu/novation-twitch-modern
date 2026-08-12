# Shared audio protocol (experimental ABI v1)

Phase 2 connects the HAL plug-in to an unprivileged helper through one anonymous
shared-memory mapping transferred over XPC.

This is still USB-independent. The helper consumes and discards frames.

The earlier POSIX name `/ntm_audio_v1` is retained only for isolated deterministic
tests. The installed 0.2.0 attempt proved that `_coreaudiod` mode-`0600`
ownership prevents a logged-in helper from opening it. The installed 0.3.0
design does not create that name and does not make any audio mapping world
writable.

## Format and capacity

- ABI version: 1
- producer: AudioServerPlugIn mixed-output callback
- consumer: one `TwitchAudioDiscardHelper` process
- channels: four, interleaved
- sample type: native-endian Float32
- rates: 44,100 or 48,000 Hz
- ring capacity: 65,536 frames
- mapped bytes: structure size rounded to the host VM page size

Absolute 64-bit frame sequences distinguish full from empty and allow wrap
without ambiguous modulo indices. The producer publishes `writeFrame` with
release ordering after copying samples. The consumer acquires it before reading,
then publishes `readFrame` with release ordering. All shared 32- and 64-bit
atomics are compile-time required to be lock-free.

## Real-time boundary

`TryWrite()` performs only:

- lock-free atomic loads/stores/increments;
- a monotonic timestamp read;
- at most two bounded `memcpy` operations.

It performs no allocation, logging, file operation, lock, wait, process launch,
or USB access. Opening and initializing the mapping happens when the plug-in is
constructed, outside `OnWriteMixedOutput()`.

When insufficient capacity remains, the complete callback is dropped and the
overrun/drop counters advance. The HAL thread never waits for the helper.

## Lifecycle and stale data

The XPC service allocates and initializes the anonymous mapping before replying
to the plug-in. The receiver validates magic, ABI version, header size, mapped
size, channel count and capacity, and refuses mismatches. The service rejects an
XPC peer whose effective UID is not `_coreaudiod` (tests use an explicit local
UID override).

Only one consumer generation may read at a time. A second helper refuses to
start while the current helper heartbeat is fresh. After one second without a
heartbeat, a replacement helper may claim a new generation; a displaced old
process fails its generation check before reading again.

Every helper start advances the read sequence to the current write sequence by
default. Delayed audio is counted in `staleFramesDiscarded` rather than played.
This makes helper-before-plug-in, plug-in-before-helper, and crash/restart order
safe for the eventual USB boundary.

## Instrumentation

The header records frame sequences, fill/high-water level, sample rate,
producer/consumer generations and active flags, callbacks, frames, drops,
overruns, underruns, start/stop counts, monotonic heartbeats, the latest Core
Audio sample time, and discarded stale frames.

Phase 2 has no downstream audio clock, so a helper underrun has no audible
meaning yet. The underrun counter exists for the future USB adapter and remains
zero in discard-only operation. Empty helper polls are intentionally not called
underruns.

The mapping is runtime state, not a file. The installed helper is an on-demand
user LaunchAgent whose executable remains inside the root-owned HAL bundle. The
service exits after a producer has stopped and its ring has drained. On a later
`StartIO`, the plug-in detects the stopped/stale consumer and acquires a fresh
mapping from the launchd-restarted service. This restart work occurs only at the
non-real-time lifecycle boundary. The test scripts and factory test continue to
use isolated POSIX names where useful
and unlink them on exit; ordinary builds never touch an installed runtime
channel.
