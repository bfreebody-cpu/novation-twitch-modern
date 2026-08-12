# ADR-002: Evaluate an AudioServerPlugIn and IOUSBHost audio bridge

- Status: experimental, accepted for bounded feasibility testing
- Date: 2026-08-12
- Tracking issue: https://github.com/bfreebody-cpu/novation-twitch-modern/issues/5
- Supersedes: nothing

## Context

The stable controller release uses IOUSBHost and Core MIDI without legacy
Novation software. The separate AudioDriverKit prototype cannot be installed
with the current Personal Team because its AudioDriverKit and USBDriverKit
capabilities require Apple-approved entitlements.

The Twitch audio transport itself is no longer speculative. Repository evidence
establishes four-channel packed-24 playback on interface 0 endpoint `0x01` at
44.1 and 48 kHz, including sustained scheduling and the physical MASTER/CUE
channel map. What remains is a Core Audio-facing device implementation.

Apple continues to document AudioServerPlugIn drivers. An AudioServerPlugIn can
publish a HAL device while a separate process owns the USB interface and exchanges
samples through a versioned shared-memory ring. The recent open-source DJM-T1
driver demonstrates this overall shape on Apple Silicon, although none of its
device-specific USB behavior is applicable to Twitch.

## Decision

Evaluate this architecture in strictly gated stages:

```text
Core Audio HAL
    -> AudioServerPlugIn
    -> versioned shared-memory ring
    -> IOUSBHost helper
    -> Twitch interface 0 / endpoint 0x01
```

The first feasibility probe is USB-independent. It publishes an experimental
four-output virtual device, advertises 44.1 and 48 kHz, and discards received
samples. It neither discovers nor opens the Twitch.

The probe will use libASPL at the exact commit recorded in
`audio/DEPENDENCIES.md`. This keeps project-specific HAL code small while using
an MIT-licensed implementation of AudioServerPlugIn boilerplate. Apple's current
minimal NullAudio sample remains the API and behavior authority.

## Isolation

- Stable controller code remains on `main`.
- Work occurs on `experiment/audio-hal-bridge` in a separate worktree.
- Experimental implementation lives under `audio/` and `scripts/audio/`.
- The existing `A3/` AudioDriverKit scaffold remains intact as an alternative.
- Phase 1 makes no USB calls and does not access the Twitch.
- No experimental audio code is merged until the gates in Issue #5 are met.

## Installation boundary

Phase 1 may build and ad-hoc sign a bundle without privilege. Installation is a
separate, explicit operation requiring administrator authorization because its
only system payload is:

```text
/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver
```

The initial probe installs no daemon, launch agent, launch daemon, privileged
helper, kernel extension, Driver Extension, receipt, or configuration file.
Uninstall removes only that exact bundle after verifying its bundle identifier,
then restarts Core Audio. See `audio/INSTALLATION_CONTRACT.md`.

## Security boundary

The experiment must not require or instruct users to disable SIP, enable Reduced
Security, use DriverKit developer mode, install the historical Novation driver,
or execute legacy binaries. Failure to load under normal macOS security is a Gate
1 failure to document, not a reason to weaken the system.

## Consequences

Positive:

- avoids restricted DriverKit entitlements for the feasibility path;
- preserves the proven userspace IOUSBHost transport;
- can potentially be built from source by technically comfortable owners;
- isolates HAL real-time work from USB scheduling and lifecycle work.

Costs and risks:

- a HAL plug-in and helper introduce IPC, buffering, clock, and lifecycle work;
- source installation requires administrator authorization;
- ad-hoc loading behavior on macOS 26 is not yet measured;
- polished distribution still needs Developer ID signing and notarization;
- a persistent helper must be justified later and is not part of Phase 1.

## Stop conditions

Stop and reassess if the minimal plug-in cannot load under normal macOS 26
security, reliable uninstall cannot be provided, or later interface-0 ownership
breaks the stable controller path.
