# Phase 2: USB-independent shared-memory bridge status

- Started: 2026-08-12
- Status: **IN PROGRESS**
- Tracking issue: https://github.com/bfreebody-cpu/novation-twitch-modern/issues/5
- Draft implementation: https://github.com/bfreebody-cpu/novation-twitch-modern/pull/6
- Gate 2: **FAILED FOR GUI-LAUNCHAGENT ARCHITECTURE**

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

The bounded 30-minute 48 kHz synthetic run completed successfully:

- 168,750 producer callbacks;
- 86,400,000 frames produced and consumed exactly;
- 2,048-frame maximum fill (3.125% of capacity);
- zero dropped frames, overruns, underruns, pattern errors, non-finite samples,
  or residual fill;
- 13 synthetic producer deadlines observed late (0.0077%); none caused data
  loss or unexplained buffer growth;
- sampled helper CPU 1.1-1.7% and producer CPU 0.2-0.4%;
- sampled resident memory approximately 2.5 MB per process;
- normal producer and consumer stop with both active flags cleared.

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

- installed HAL producer to independently running helper delivery;
- both Core Audio sample rates through the installed plug-in;
- helper-before-HAL and HAL-before-helper behavior in the actual Core Audio host;
- helper exit/restart during actual Core Audio output;
- bounded 30-minute Core Audio run with CPU and frame-accounting evidence;
- post-test uninstall/reboot verification.

## First installed attempt and blocker

The version 0.2.0 Phase 2 bundle was installed and loaded after a normal reboot
with SIP unchanged. Measured after reboot:

- exact bundle identifier and ad-hoc signature validated;
- Core Audio loaded the driver as `_coreaudiod` (UID/GID 202);
- the virtual device published four outputs at the current 48 kHz rate;
- no helper was already running and no related crash report was present.

The first logged-in-user helper attachment stopped immediately with:

```text
shared-memory open failed: Permission denied (errno=13)
```

This is an established cross-UID permission failure, not an audio, ring, or USB
failure. The plug-in created `/ntm_audio_v1` with mode `0600` as `_coreaudiod`;
the helper ran as UID 501/GID 20. The two identities have no suitably private
common group.

No helper was run as root, no permission was changed, no Core Audio stream was
started, and no USB device was accessed.

## IPC correction decision

Do not change the mapping to mode `0666`. The pinned DJM-T1 precedent uses a
root launch daemon and requests a world-readable/writable POSIX object, but that
would let unrelated local processes alter future physical-output samples or
ring state.

The current macOS 26.5 SDK `AudioServerPlugIn.h` explicitly supports plug-in
communication with declared Mach services through the
`AudioServerPlugIn_MachServices` Info.plist key. The public XPC API supports
passing shared-memory objects with `xpc_shmem_create()` and
`xpc_shmem_map()`. Phase 2 will therefore replace name/permission-based
cross-UID attachment with an XPC-mediated shared-memory handoff before another
installation attempt.

This changes the Phase 2 installation footprint and lifecycle contract, so the
0.2.0 plug-in must be uninstalled and the Mac rebooted before implementation or
testing continues. Gate 2 remains open.

## Corrected XPC implementation and local validation

The 0.2.0 bundle was removed through the validated uninstaller and a normal
reboot confirmed the virtual device, driver process and bundle were absent.

Version 0.3.0 now implements the reviewed correction without USB access:

- a logged-in-user LaunchAgent advertises
  `com.twitchmodern.NovationTwitchModernAudioExperimental.bridge` on demand;
- its executable is embedded in the root-owned HAL bundle;
- the service allocates an anonymous shared mapping and transfers it with
  `xpc_shmem_create()` / `xpc_shmem_map()`;
- the installed path accepts only the `_coreaudiod` effective UID;
- the plug-in declares the service in `AudioServerPlugIn_MachServices` and
  reconnects at `StartIO` if it was loaded before the user's agent existed;
- the on-demand helper exits after a completed/drained stream, and a later
  `StartIO` rejects its stale mapping and reacquires a launchd-restarted service;
- the real-time mixed-output callback remains XPC-free and lock-free;
- named POSIX shared memory remains only as an isolated test transport.

Local launchd tests, run wholly as UID 501, established actual two-process Mach
service discovery and anonymous-memory transfer:

| Rate | Producer frames | Consumer frames | High water | Drops/overruns | Pattern errors |
|---:|---:|---:|---:|---:|---:|
| 44,100 | 132,608 | 132,608 | 512 | 0 / 0 | 0 |
| 48,000 | 144,384 | 144,384 | 512 | 0 / 0 | 0 |

Both tests had zero residual fill and zero non-finite samples. A separate
negative test configured a deliberately unmatched allowed UID and confirmed the
service rejected the client. The factory test, ring tests, bundle signature and
bundle identifier also pass.

The revised installation contract now contains two exact payloads: the HAL
bundle installed with administrator authorization and one user LaunchAgent
plist installed without `sudo`. No daemon, root helper, world-writable mapping,
security-policy change, USB access or legacy execution is introduced.

The remaining immediate uncertainty is whether `_coreaudiod` can discover this
service in the logged-in GUI bootstrap domain on the tested macOS release. That
cross-domain lookup cannot be established by the same-UID local harness. The
next bounded installation exists solely to answer that question before live
audio or helper-restart work continues.

## Installed 0.3.0 cross-domain result

The 0.3.0 bundle and its user LaunchAgent were installed, validated, and loaded
after a normal reboot with SIP unchanged. macOS published the experimental
four-output virtual device at 48 kHz. The LaunchAgent was enabled and registered
in `gui/501`, but remained on demand with zero launches.

At plug-in load, macOS explicitly recognized
`AudioServerPlugIn_MachServices` and extended the isolated driver host sandbox
for the declared service. The subsequent lookup nevertheless occurred in the
system bootstrap domain:

```text
failed lookup: name = com.twitchmodern.NovationTwitchModernAudioExperimental.bridge,
requestor = com.apple.audio[510], error = 3: No such process
```

The plug-in logged `XPC bridge service is unavailable`. A bounded 48 kHz Core
Audio run then completed 469 callbacks / 240,128 frames and a clean
StartIO/StopIO, but the helper launch count remained zero and no bridge log was
created. Those frames were intentionally discarded by the fail-open plug-in;
this was not successful IPC delivery.

This establishes that an AudioServerPlugIn hosted as `_coreaudiod` cannot reach
a Mach service advertised solely by the logged-in user's LaunchAgent on the
tested macOS 26.5.2 system. Same-UID XPC tests remain valid evidence for the
transport implementation, but do not solve bootstrap-domain visibility.

No helper ran as root, no world-writable mapping or permission workaround was
introduced, and no USB device was opened. The planned live rate, restart, and
30-minute tests are blocked and were not attempted.

A new observation was also recorded after this reboot: the user's Logitech Wave
Keys 670 required a second connection wait after sign-in. Bluetooth logs show
the keyboard reconnecting and negotiating HID parameters roughly 50 seconds
after the audio plug-in loaded. The Twitch LaunchAgent had zero runs, so it
cannot directly explain the delay; causation by the otherwise idle HAL plug-in
is also not established. Rechecking after the required uninstall reboot is the
clean control.

## Gate 2 decision

**NO for the user-LaunchAgent design.** Do not proceed to USB, helper restart,
or sustained Core Audio work on this topology. Do not move the same helper to a
root LaunchDaemon or weaken shared-memory permissions without a new, explicit
security and lifecycle architecture review. The installed experimental payloads
should be removed in the documented user-then-root order and followed by a
normal reboot.
