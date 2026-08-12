# Phase 1: USB-independent HAL feasibility status

- Date completed: 2026-08-12
- Platform: Apple Silicon (`arm64`)
- macOS: 26.5.2 (25F84)
- Xcode: 26.6 (17F113)
- Tracking issue: https://github.com/bfreebody-cpu/novation-twitch-modern/issues/5
- Draft implementation: https://github.com/bfreebody-cpu/novation-twitch-modern/pull/6
- Gate 1: **PASSED**

## Scope

This phase tested only whether a locally built AudioServerPlugIn can publish a
four-output Core Audio device under normal macOS 26 security. The probe contains
no Twitch discovery or USB code and discards all output samples.

## Build and signature

- Built successfully from the isolated `experiment/audio-hal-bridge` worktree.
- Pinned libASPL commit: `633e0f70203edd87d320fc5a3cae901e1363aac5`.
- Output: arm64 Mach-O AudioServerPlugIn bundle.
- Bundle identifier:
  `com.twitchmodern.NovationTwitchModernAudioExperimental`.
- Ad-hoc signature passed `codesign --verify --deep --strict`.
- Factory/load/type-filter test passed.
- Binary linked CoreFoundation and system C/C++ libraries only; no IOKit,
  IOUSBHost, USBDriverKit, or Twitch transport linkage was present.

## Installation and security

The administrator-authorized installer copied exactly:

```text
/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver
```

The installed bundle had `root:wheel` ownership and a valid signature.

An attempted live `launchctl kickstart` of the protected system `coreaudiod`
service returned status 150 while SIP was enabled. No bypass was attempted. The
scripts were corrected to follow Apple's NullAudio guidance and require a normal
reboot after installation/removal.

After a normal reboot, macOS loaded the ad-hoc bundle with SIP enabled and
launched `Core Audio Driver (NovationTwitchModernAudioExperimental.driver)`.
No restricted DriverKit entitlement, paid Developer ID, SIP change, or Reduced
Security mode was required for this local source-built feasibility test.

## Published Core Audio device

Measured through Core Audio and `system_profiler`:

- Name: `Novation Twitch Modern Audio - Experimental`
- Manufacturer: `Novation Twitch Modern community`
- Transport: virtual
- Output channels: 4
- Input channels: 0
- Discrete nominal rates: 44,100 and 48,000 Hz
- Default/current rate after testing: 48,000 Hz

The live HAL verifier completed StartIO/StopIO cycles at both rates:

```text
device=99 output_channels=4 rates=44100-44100 48000-48000
io rate=44100 callbacks=44 frames=22528
io rate=48000 callbacks=47 frames=24064
PASS: HAL discovery, channel/rate inventory, and StartIO/StopIO
```

All callbacks carried generated silence to the discard-only probe. No physical
audio output or Twitch access occurred.

## Mixxx result

Mixxx 2.5.6 discovered `Novation Twitch Modern Audio - Experimental` in Sound
Hardware. Main was assigned to channels 1/2 and Headphones to channels 3/4.
A track played normally in the UI and deck PFL/headphone cue was exercised.
Silence was expected and observed because the probe discards samples. Mixxx
reported no error and quit normally. No Mixxx or plug-in crash report appeared.

The discovery screenshot is retained at
`docs/images/audio-hal-mixxx-discovery.png`.

## Uninstall result

The administrator-authorized uninstaller validated the exact bundle identifier
and removed only the project-owned path. After a normal reboot:

- the installed bundle was absent;
- the experimental Core Audio device was absent;
- no experimental Core Audio Driver process remained;
- no relevant crash report was present.

The installation/removal contract is therefore repeatable on the tested Mac.

## Regression results

- HAL factory test: passed
- HAL live discovery/lifecycle test: passed
- `twitch-parser-tests`: passed
- `twitch-a1-tests`: passed
- `twitch-a3-tests`: passed
- deterministic Mixxx mapping tests: passed
- shell syntax, plist, signature, and repository diff checks: passed

## Decision

**Gate 1: PASSED.** A source-built, ad-hoc-signed AudioServerPlugIn can publish
the required four-channel/two-rate Core Audio shape on the tested Apple Silicon
Mac without restricted DriverKit entitlements or weakened security.

**Phase 2 ready: YES.** The next authorized phase is still USB-independent: add
a versioned shared-memory ring and an unprivileged helper that consumes/discards
Core Audio output, then validate lifecycle and a bounded 30-minute run. Do not
connect the Twitch transport until Gate 2 passes.
