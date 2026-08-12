# Shared audio protocol (experimental ABI v1)

Phase 2 connects the HAL plug-in to an unprivileged helper through one POSIX
shared-memory object:

```text
/ntm_audio_v1
```

This is still USB-independent. The helper consumes and discards frames.

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

Either process may create the mapping first. Exclusive creation selects one
initializer; a release/acquire magic value publishes the completed header.
Openers validate magic, ABI version, header size, mapped size, channel count and
capacity, and refuse mismatches.

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

The object is runtime state, not an installed daemon or configuration file. The
test scripts and factory test use isolated names and unlink them on exit;
ordinary builds never unlink an installed plug-in's default channel. The
default object is removed by the uninstall workflow; reboot also destroys the
process mappings.
