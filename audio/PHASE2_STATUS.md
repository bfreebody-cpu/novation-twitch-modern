# Phase 2: USB-independent shared-memory bridge status

- Started: 2026-08-12
- Status: **IN PROGRESS**
- Tracking issue: https://github.com/bfreebody-cpu/novation-twitch-modern/issues/5
- Draft implementation: https://github.com/bfreebody-cpu/novation-twitch-modern/pull/6
- Gate 2: **NOT YET DECIDED**

## Scope

Phase 2 connects Core Audio output to a separate unprivileged process through a
versioned shared-memory ring. The helper still discards all samples. No code in
this phase discovers, opens or transfers data to the Twitch or any USB device.

## Implemented

- ABI-v1 four-channel interleaved Float32 SPSC ring
- 65,536-frame bounded capacity
- 44.1/48 kHz sample-rate publication
- lock-free real-time producer data path
- drop-on-full behavior with no HAL-thread wait or retry
- monotonic producer/consumer heartbeats
- frame, callback, fill, high-water, lifecycle, drop and error counters
- Core Audio sample-time capture
- protocol, size and layout mismatch refusal
- helper-before-plug-in and plug-in-before-helper ordering
- single live consumer enforcement
- stale consumer generation takeover
- stale audio discard on helper attach/restart
- SIGINT/SIGTERM helper shutdown and JSON-lines metrics
- deterministic synthetic pattern validation across two processes
- factory/build tests isolated from the installed runtime mapping
- bounded live-HAL and live helper-restart harnesses (installation-gated)

## Measured before HAL installation

Deterministic unit coverage passes for data integrity, ring wrap, full-ring
drop behavior, sample-rate state, lifecycle counters, start ordering, consumer
ownership, stale takeover, helper restart and protocol-version mismatch.
The concurrent 640,000-frame SPSC test also passes under AddressSanitizer,
UndefinedBehaviorSanitizer and ThreadSanitizer.

Two-process 10-second runs passed independently at 48 and 44.1 kHz:

| Rate | Producer frames | Consumer frames | High water | Drops/overruns | Pattern errors |
|---:|---:|---:|---:|---:|---:|
| 48,000 | 480,256 | 480,256 | 512 | 0 / 0 | 0 |
| 44,100 | 441,344 | 441,344 | 512 | 0 / 0 | 0 |

A continuous-helper rate-change test then received 276,992 frames across a
48 kHz producer session followed by a 44.1 kHz session. The final published
rate was 44,100, producer generation advanced to 2, high water remained 512
frames, and all drop, overrun, pattern and non-finite counters remained zero.

An abrupt helper-termination/restart test passed while the producer continued:

- old helper killed without a graceful stop;
- a simultaneous second helper was refused while the first heartbeat was live;
- replacement claimed consumer generation 2 after the stale threshold;
- 78,336 accumulated frames were identified and discarded as stale;
- 216,576 frames were consumed across the helper processes;
- producer submitted 336,384 frames;
- high-water mark was 53,760 of 65,536 frames;
- zero overrun, dropped-frame, pattern, or non-finite-sample errors.

The required bounded 30-minute synthetic run is currently in progress. Its
final counters will be added here after completion.

Existing controller and audio regressions remain green:

- `twitch-parser-tests`
- `twitch-a1-tests`
- `twitch-a3-tests`
- deterministic Mixxx mapping tests

The Phase 2 bundle links CoreFoundation, libc++, and libSystem only. Inspection
finds the expected POSIX shared-memory symbols and no IOKit, IOUSBHost or
USBDriverKit linkage.

A live default-name helper remained attached while the factory test loaded and
unloaded its isolated mapping. This confirms an ordinary build/test cycle no
longer unlinks or mutates an installed plug-in's runtime namespace.

## macOS-specific implementation finding

On macOS 26, POSIX shared-memory descriptors reject `flock` with
`ENOTSUP`, and `ftruncate` rounds the reported object size to the 16 KiB VM page
boundary. The implementation therefore uses exclusive creation plus an explicit
release/acquire initialization marker and validates the page-rounded mapping
size. This behavior was discovered by the deterministic test rather than hidden
by a retry.

## Remaining Gate 2 evidence

- final 30-minute USB-independent synthetic result;
- installed HAL producer to independently running helper delivery;
- both Core Audio sample rates through the installed plug-in;
- helper-before-HAL and HAL-before-helper behavior in the actual Core Audio host;
- helper exit/restart during actual Core Audio output;
- bounded 30-minute Core Audio run with CPU and frame-accounting evidence;
- post-test uninstall/reboot verification;

No administrator action has been requested and the updated plug-in has not been
installed. Gate 1's prior bundle remains uninstalled.
