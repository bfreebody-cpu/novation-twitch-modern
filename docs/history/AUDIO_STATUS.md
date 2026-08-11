# Audio-restoration status

Date: 2026-08-10/11 (America/Toronto)

## Checkpoint and scope

- Controller v1 checkpoint: `b2d4bce Complete Twitch bidirectional Mixxx integration`
- Current branch: `audio-restoration`
- Controller code changed in this phase: **no**
- Audio implementation code created: **yes, isolated A1/A1.5 executables,
  library and shim**
- Audio endpoints opened or transferred: **yes, bounded interface-0 A1 and
  sustained A1.5 tests only**
- Legacy software installed/executed: **no**
- Reference files modified: **no**

The M0-M4 controller sources remain byte-for-byte unchanged from the checkpoint.

## A1 completion update

Canonical capture: `captures/20260810T231803.901Z-twitch-a1-audio/`.

- Exact 48 kHz `SET_CUR` succeeded; three-byte `GET_CUR` returned `80 bb 00`.
- `0x82` returned variable 282/288/294-byte, nontrivial payloads across bounded
  observations. The canonical 250-frame run contained 238 × 288 and 12 × 294.
  This is audio-data-sized behavior, not explicit 3/4-byte feedback.
- 2,000/2,000 nominal 576-byte four-channel silence frames completed with
  concurrent 2,000/2,000 `0x82` reads and no USB error.
- Four separately drained one-second 440 Hz, -48 dBFS packed-24 tone segments and
  three one-second silence separators completed without error.
- Headphone observations under centered MASTER/CUE MIX were channel 1 left,
  channel 2 right, channel 3 both, and channel 4 right. The operator also had
  MASTER/monitoring controls slightly open, so A1 alone did not establish
  isolated analog routing; A1.5 later resolved it.
- Controller PLAY input and Mixxx LED response worked before, during and after
  A1; interface 1 remained owned by the unchanged M4 bridge.
- Normal shutdown, prompt-time Ctrl-C, and Ctrl-C during an active `0x82` frame
  list restored interface 0 to alternate 0. Pre/post device registry identity
  and configuration matched.

**A1 COMPLETE: YES. A1.5 READY: YES.**

## A1.5 completion update

Detailed evidence and capture provenance are in `A1_5_STATUS.md`.

- A 16-frame sustained queue failed closed after 140.556 seconds when a measured
  18.108 ms completion gap exhausted its lead. It did not retry or submit a
  stale frame.
- A bounded 64-frame, 8-batch × 8-frame validation policy then passed a
  three-minute proof, 30 minutes at 48 kHz and ten minutes at 44.1 kHz.
- The 30-minute 48 kHz run completed 1,800,000 × 576-byte OUT packets and
  1,800,000 IN packets with zero USB errors, short OUT packets, late submissions
  or `kIOReturnIsoTooOld`. IN acquired a +5-audio-frame startup offset and kept
  exactly that offset for every one-second aggregate; it did not drift.
- The ten-minute 44.1 kHz run completed the exact OUT cadence of 540,000 × 528
  bytes and 60,000 × 540 bytes. IN used the corresponding 264/270-byte cadence
  with a fixed -3-frame startup offset and no accumulated drift.
- `SET_CUR`/`GET_CUR` physically verified both `80 bb 00` and `44 ac 00`.
- Controlled MIC and AUX tests prove that `0x82` carries capture audio. AUX LEFT
  maps to capture channel 1, AUX RIGHT to channel 2, and the mono MIC appears on
  both capture channels. Stereo packed-24 little-endian is strongly supported;
  exact scaling remains an A2 question.
- Controlled headphone routing proves playback channels 1/2 are MASTER
  left/right and 3/4 are CUE left/right. BOOTH with its source switch at MASTER
  and the direct balanced MASTER jacks also reproduce channels 1/2 left/right.
- The older short A1 scheduler reproduced `IsoTooOld`; applying A1.5's measured
  64-frame, 8-by-8 bounded queue policy eliminated it in all subsequent routing
  gates without retries.
- The controller and Mixxx-driven LEDs coexisted throughout the three-minute and
  ten-minute runs and for 29m46s of the 30-minute run. The last 14 seconds were
  outside the controller bridge's independent safety timer, not a USB audio
  failure.
- All completed sustained runs restored interface 0 to alternate 0.
- The final 27-minute controller/audio coexistence session shut down cleanly
  after all routing tests with an empty LED-output queue, zero Core MIDI errors,
  unchanged USB session identity, and both interfaces idle at alternate 0.

**A1.5 COMPLETE: YES. A2 READY: YES. A3 PLAYBACK-ONLY READY: YES.**

## A3 implementation update

A3 began from checkpoint `329c00b`. The transport-independent four-channel
Float32-to-S24_3LE packetizer, dual-rate cadence and bounded ring behavior are
implemented and pass deterministic tests. No Twitch USB access occurred in A3.

Xcode 26.6 is installed and selected. Its macOS 26.5 and DriverKit 25.5 SDKs,
AudioDriverKit, USBDriverKit and `iig` were verified. An attributed containing
app plus playback-only dext scaffold now compiles unsigned and embeds correctly;
the dext matches only Twitch interface 0, declares four Float32 output channels
at 44.1/48 kHz and compiles its USB open/alt/endpoint/restore lifecycle. It does
not yet submit isochronous traffic or issue rate requests and was not activated.
The final unsigned app build succeeded for arm64 with a universal dext; three
ownership analyzer warnings remain for pre-activation cleanup.

The remaining external boundary is entitlement provisioning. Xcode is signed in
and displays an Apple Development certificate, but its selected Personal Team
cannot create profiles with System Extension, DriverKit, Audio Family, Allow Any
UserClient, or USB Transport capabilities. An eligible Apple Developer Program
team and Apple approval are needed for the complete entitlement group, including
USB transport restricted to `0x1235:0x0018`. Security validation was not
disabled.

**A3 COMPLETE: NO — core and unsigned scaffold build; signing, remaining USB
implementation, activation and live validation are outstanding.**

**A4 READY: NO.**

## Completed research

### Existing evidence reconciled

- Rechecked the measured interface-0 descriptors and endpoint limits.
- Re-traced the Twitch fixed-playback entry through canonical Linux quirk,
  stream, PCM, clock and endpoint code at commit
  `db2ddb87143519e20a95aa36c60b36107b736a58`.
- Recorded the exact 44.1/48 kHz endpoint-class `SET_CUR`/`GET_CUR` requests.
- Sharpened Linux's `0x82` behavior: generic code infers it as a non-implicit sync
  endpoint for the playback format even though the physical descriptor labels it
  as data, provides no sync address and allows 294 bytes.
- Reconfirmed that Linux exposes only four-channel `S24_3LE` playback for Twitch;
  it has no Twitch capture quirk.
- Reconciled packet arithmetic with the physical 588/294-byte limits and Apple's
  current USB-audio clock guidance.

### Historical package static study

The 3.1.699 DMG was mounted read-only, its installer expanded as data in a
temporary directory, and the audio kext inspected with metadata/symbol/string/
disassembly tools. It was never installed or executed; the image was detached and
the temporary extraction was moved to Trash.

Useful findings:

- Twitch matches interface 0 through `IOUSBHostInterface`.
- The Twitch-specific code selects alternate 1 when needed, discovers isochronous
  pipes by direction and derives maximum packet sizes.
- It constructs a two-input/four-output engine with separate frame-list read and
  write completion paths.
- It has 44.1/48 kHz and sample-rate-dependent endpoint/buffer setup.
- The binary is x86_64, IOAudioFamily-era and proprietary: behavioral evidence
  only, not reusable code.
- Apple's current TN3190 confirms that macOS Tahoe 26 no longer publishes the
  deprecated IOAudioFamily kernel services on which that design depended.

### Current macOS architecture study

- Current [AudioDriverKit](https://developer.apple.com/documentation/audiodriverkit)
  directly connects a physical Driver Extension to Core Audio HAL and removes the
  need for an AudioServerPlugIn.
- Apple's current AudioDriverKit sample says a physical audio device class may
  communicate with USB hardware with the appropriate transport entitlement.
- USBDriverKit can match/own interface 0 and provides alternate selection,
  control requests, USB frame time and isochronous pipes.
- The older AudioServerPlugIn + USB Driver Extension sample remains a supported
  fallback/reference, but is not the simplest current product architecture.
- DriverKit distribution requires an app/system extension, signing and an
  Apple-approved complete entitlement group.
- This Mac has macOS 26.5.2; Xcode 26.6 is selected and provides macOS 26.5 and
  DriverKit 25.5 SDKs. The unsigned DriverKit project now builds.

### Reuse/licensing study

- Apple AudioDriverKit samples: primary reusable architecture; Apple Sample Code
  License.
- `djm-t1-driver`: MIT and the closest public non-class DJ-audio design, useful
  for isochronous/ring/test concepts; its libusb daemon + AudioServerPlugIn shape
  and device-specific fixed packet policy are not the recommended Twitch product
  base.
- libASPL: MIT, production-oriented AudioServerPlugIn boilerplate; fallback only.
- BlackHole: GPL-3.0 and virtual-only; useful as study material but creates
  copyleft/branding constraints.
- libusb: LGPL-2.1-or-later, viable dynamically linked diagnostic fallback.
- Linux local sources: GPL-2.0-or-later files; reimplement behavior independently
  unless the project intentionally adopts compatible GPL obligations.
- Novation binaries: no adaptation grant found; no code reuse.
- The repository itself has no declared top-level license, so third-party code
  must not be copied until project licensing is chosen.

## Recommended architecture

### Research

`Twitch interface 0 -> IOUSBHost scheduled isochronous harness -> evidence only`

Use the existing native API and discovery/evidence patterns. Fall back to libusb
only if an exact IOUSBHost limitation is demonstrated.

### Product

`Twitch interface 0 -> USBDriverKit transport inside AudioDriverKit dext -> Core Audio HAL -> Mixxx`

Match only interface 0 so the stable IOUSBHost/Core MIDI controller bridge can
continue to own interface 1. Do not build an AudioServerPlugIn unless direct
AudioDriverKit proves insufficient.

## Expected custom Twitch implementation

- interface/alternate ownership and rate-control sequence;
- `S24_3LE` four-channel packing/conversion;
- USB frame scheduling and bounded queues;
- `0x82` role/feedback handling;
- master/headphone/cue channel map;
- rate changes and later capture format;
- USB-frame-to-Core-Audio timestamp/latency model;
- underrun, overrun, disconnect, sleep/wake and controller-coexistence handling.

Core Audio object publication and USB transport primitives should come from
Apple frameworks rather than custom equivalents.

## Remaining evidence gaps

1. Exact `0x82` numeric scaling/sign extension and whether its capture cadence
   is also the playback clock reference.
2. BOOTH with its source switch at CUE; direct balanced MASTER, BOOTH-at-MASTER,
   and headphone MASTER/CUE routes are mapped.
3. Whether production OUT must wait for stable IN or merely run concurrently.
4. The smallest production safety offset: 64 ms is validated robustness
   headroom, not a final latency choice.
5. Sleep/wake, unplug/reconnect, post-rate-change idle and overload behavior for
   audio. Repeated short sessions produced successful zero-length IN transfers
   until a physical replug; cause and software recovery are unresolved.
6. Whether an interface-0 AudioDriverKit dext and the current controller bridge
   expose the predicted startup ownership conflict.
7. Persistent Core MIDI endpoint lifecycle across Twitch removal; current
   process exit can leave stale endpoint references in Mixxx.
8. Project license and future Apple entitlement approval.

## Blockers

### To a Core Audio driver

- review of completed A1.5 analog/routing evidence;
- an eligible Apple Developer Program team and DriverKit provisioning profiles
  (the measured Personal Team cannot provide them);
- a chosen project license;
- eventual DriverKit Audio + USB entitlement strategy;
- capture characterization if input is included in v1.

## Recommended next actions

1. Review `A1_5_STATUS.md`, including the analog and routing captures.
2. Choose A2 full-duplex characterization or A3 playback-only Core Audio work.
3. Preserve the proven scheduler and investigate the zero-length-IN lifecycle
   state before relying on capture in a product.
4. Configure the Apple team/certificate and request the complete DriverKit
   entitlement group before any activation attempt.

## Exact next milestone

Choose and authorize one separate track:

- **A2 capture/full-duplex characterization**, including exact sample semantics
  and lifecycle recovery; or
- **A3 playback-only Core Audio prototype**, exposing four output channels while
  retaining capture as deferred research.

## Estimate

- A1: 3-7 engineering days
- A1.5: 3-7 days
- A2 capture/full duplex: 1-2 weeks
- AudioDriverKit prototype: 2-4 weeks
- hardening/distribution: 3-6 weeks

Revised total: approximately **7-13 engineering weeks**, plus Apple entitlement
lead time. Playback-only v1 may be shorter; unresolved `0x82` behavior or an
AudioServerPlugIn fallback would extend it.

## Readiness decision

**A1 COMPLETE: YES**

**A1.5 COMPLETE: YES.**

**A2 READY: YES.**

**A3 PLAYBACK-ONLY READY: YES.**

A1.5 now proves sustained, drift-free nominal cadence at both supported rates,
capture behavior and AUX/MIC mapping, and the MASTER/CUE playback channel map.
It eliminates the stale-schedule defect with bounded measured headroom. Exact
capture scaling, BOOTH-at-CUE confirmation and lifecycle recovery remain
later-stage work.
