# Novation Twitch audio-restoration architecture

Date: 2026-08-10 (America/Toronto)
Target: Novation Twitch USB `0x1235:0x0018`, Apple silicon, macOS 26

## 1. Decision

The minimum-risk path has two deliberately separate layers:

1. Prove the Twitch wire protocol with a short-lived, non-Core-Audio
   `IOUSBHost` playback harness that owns only USB interface 0.
2. After playback, clocking, channel order and capture are measured, expose the
   physical device with one AudioDriverKit Driver Extension that also uses
   USBDriverKit for interface-0 transport.

The second layer supersedes the older product architecture proposed in
`ARCHITECTURE.md`. Apple's current
[AudioDriverKit overview](https://developer.apple.com/documentation/audiodriverkit)
states that AudioDriverKit communicates directly with Core Audio HAL, eliminates
the need for an AudioServerPlugIn, and can integrate transport DriverKit
frameworks. Apple's current
[physical audio-device sample](https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver)
also says the audio device class is responsible for hardware communication over
USB or PCI and needs the relevant transport entitlement.

An AudioServerPlugIn plus a USB-owning process/dext remains a fallback, not the
recommended first product design. Apple's
[plug-in plus Driver Extension sample](https://developer.apple.com/documentation/coreaudio/building-an-audio-server-plug-in-and-driver-extension)
is still useful as IPC and lifecycle reference, but it predates the simpler
direct AudioDriverKit relationship.

The completed controller implementation is a stable subsystem and is not part of
this research implementation surface.

## 2. Evidence vocabulary

This document uses these labels strictly:

- **Supplied evidence:** manuals, Programmer's Reference, historical packages and
  archived material supplied in this repository.
- **Canonical source:** byte-verified upstream Linux source pinned at commit
  `db2ddb87143519e20a95aa36c60b36107b736a58`.
- **Physical observation:** data measured from the connected Twitch by the M0-M4
  tools and preserved under `captures/`.
- **Historical static evidence:** metadata, symbols, strings and disassembly read
  from the old Novation packages without installing or executing them.
- **Current platform evidence:** current Apple documentation and the macOS 26.5
  SDK/runtime on this Mac.
- **Hypothesis:** anything not established by one of those sources and requiring
  a controlled hardware test.

Similarity, arithmetic plausibility and old-driver behavior are not promoted to
physical facts.

## 3. Established Twitch USB audio facts

### 3.1 Physical descriptors

**Physical observation:** the unit is a full-speed 12 Mb/s USB 1.0 device with
one configuration and two vendor-specific interfaces. Interface 0 is the audio
function:

| Interface/alternate | Endpoint | Descriptor facts |
|---|---|---|
| 0/0 | none | idle state |
| 0/1 | `0x01` OUT | isochronous, synchronization `none`, usage `data`, max packet 588, interval 1, 7-byte descriptor, no `bSynchAddress` |
| 0/1 | `0x82` IN | isochronous, synchronization `none`, usage `data`, max packet 294, interval 1, 7-byte descriptor, no `bSynchAddress` |

There are no class-specific audio descriptors. The built-in Apple USB Audio
driver therefore has no format/topology description to consume, and the
vendor-class interface does not bind as a normal USB Audio Class device.

**Physical observation:** interface 1 independently carries the proven raw-MIDI
controller on interrupt endpoints `0x03`/`0x84`. A1/A1.5 physically showed that
the unchanged M4 bridge can retain interface 1 and bidirectional controller
traffic while the audio harness owns interface 0 and schedules `0x01`/`0x82`.

### 3.2 Playback format

**Canonical source:** Linux's Twitch quirk defines only this PCM stream:

- playback endpoint `0x01`;
- interface 0, alternate 1, endpoint index 0;
- four channels;
- `S24_3LE`, signed packed 24-bit little-endian;
- 44,100 and 48,000 samples/s;
- endpoint sampling-frequency control;
- isochronous transport.

The physical maximum packet size is exactly the upper bound Apple gives for a
full-speed 48 kHz, four-channel, packed-24 asynchronous schedule: 49 frames × 4
channels × 3 bytes = 588 bytes. Apple's
[TN3190](https://developer.apple.com/documentation/technotes/tn3190-usb-audio-device-design-considerations)
uses this same calculation, but the Twitch descriptor's synchronization bits do
not describe an asynchronous data endpoint. The size corroborates capacity, not
the clock model.

Nominal payload arithmetic is:

| Rate | Audio frame | Nominal USB-frame schedule |
|---:|---:|---|
| 48 kHz | 12 bytes | 48 frames / 576 bytes each millisecond; 588 permits a 49-frame correction |
| 44.1 kHz | 12 bytes | 44 or 45 frames / 528 or 540 bytes according to a phase accumulator |

Packed signed-24 silence is all zero bytes.

### 3.3 Exact Linux initialization path

**Canonical source:** the complete local trace is catalogued in
`reference/linux/MANIFEST.md` (`reference/linux/MANIFEST.md`). For Twitch, Linux:

1. matches the composite quirk for `0x1235:0x0018`;
2. runs `snd_usb_novation_boot_quirk()` before constructing streams;
3. selects interface 0 alternate 1, ignoring that call's return value;
4. builds a fixed playback stream from the quirk rather than audio descriptors;
5. derives data interval and maximum packet size from alternate index 1;
6. infers a possible synchronization endpoint from the alternate descriptor;
7. registers endpoint `0x01` and any inferred sync endpoint;
8. returns interface 0 to alternate 0;
9. skips pitch initialization because the Twitch quirk advertises sample-rate
   control but not pitch control; and
10. initializes the endpoint rate to `rate_max`, 48 kHz.

The UAC1/default rate request in canonical `clock.c` is exact:

- `bmRequestType = 0x22` (host-to-device, class, endpoint);
- `bRequest = SET_CUR (0x01)`;
- `wValue = 0x0100` (sampling-frequency selector);
- `wIndex = 0x0001` (endpoint `0x01`);
- three little-endian rate bytes: `80 bb 00` for 48,000 or `44 ac 00` for 44,100.

Linux normally follows with `GET_CUR` using `bmRequestType = 0xa2`,
`bRequest = 0x81`, the same value/index and a three-byte response. A readback
failure is treated as nonfatal by Linux; a mismatched nonzero value is logged.

At actual stream preparation the UAC1 path selects interface 0 alternate 1
before repeating rate setup. This is the most defensible A1 ordering.

### 3.4 The `0x82` clock/capture ambiguity

This is the highest protocol risk.

**Canonical source:** the Twitch table defines no capture stream and no explicit
sync fields. Nevertheless, `snd_usb_audioformat_set_sync_ep()` sees a playback
OUT endpoint with synchronization bits `none` and a second isochronous IN
endpoint. Because both endpoint descriptors are only seven bytes, the generic
logic cannot validate `bSynchAddress`; it assigns `0x82` as a sync endpoint. Its
usage bits are `data`, not `implicit feedback`, so current Linux treats it as an
explicit-style sync endpoint, requests four bytes, accepts at least three, and
interprets them as a full-speed feedback value.

**Physical observation:** `0x82` can carry up to 294 bytes per millisecond. That
equals 49 × 2 × 3 and is consistent with, but does not prove, two-channel packed
24-bit capture.

**Supplied evidence:** the user manual says Twitch supports 16-bit recording. It
does not specify the USB wire format.

**Historical static evidence:** the Novation 3.1.699 kext constructs an engine
with two input and four output channels and has separate isochronous read and
write paths. It discovers the IN and OUT pipes from descriptors rather than
hard-coding their addresses.

A1/A1.5 eliminate the explicit-feedback interpretation for full-size reads: `0x82` returned
audio-frame-sized 282/288/294-byte packets at 48 kHz and 264/270-byte packets at
44.1 kHz, with nontrivial payloads. Its aggregate candidate audio-frame count
maintained a fixed phase offset from OUT without accumulated drift at both
rates. This establishes clock-correlated, two-channel-audio-frame-shaped data,
not explicit feedback.

Controlled microphone and left/right AUX injection subsequently proves that the
payload is capture audio: AUX LEFT maps to candidate channel 1, AUX RIGHT to
channel 2, and mono microphone input appears on both. Lengths and decoded signal
behavior strongly support stereo signed packed-24 little-endian transport. Exact
numeric scaling and whether playback must actively follow the IN cadence remain
open.

## 4. Historical Novation package value

The two DMGs remain unmodified. They were not installed and no contained binary
was executed. Read-only mounting, package expansion as data, property-list
inspection, symbols, strings and static disassembly are safe research operations.

Static inspection of version 3.1.699 establishes:

- an x86_64-only `NovationUSBAudio.kext`, built with the macOS 10.14 SDK;
- bundle ID `com.novationmusic.driver.usb.audio`, using obsolete
  `IOAudioFamily`/kext architecture;
- a Twitch personality matching vendor 4661, product 24, configuration 1,
  interface 0, provider `IOUSBHostInterface`;
- a Twitch-specific class that ensures alternate 1, searches for isochronous IN
  and OUT endpoints by direction, obtains their pipes/max packet sizes, and
  constructs a two-input/four-output engine;
- separate frame-list read/write scheduling and completion handlers;
- 44.1/48 kHz preparation paths and sample-rate-dependent endpoint/buffer setup;
- restoration to alternate 0 outside active streaming.

Useful remaining static work, if A1 exposes an ambiguity, is narrowly targeted
control-flow reconstruction of `PrepareForSampleRate`, `StartReadTransfer`,
`StartWriteTransfer`, and the Twitch engine constructor, plus a cross-version
2.7/3.1.699 diff. It may reveal request order, number of queued frame lists,
latency constants and whether IN must start before OUT.

The package is proprietary binary evidence. No source license authorizes copying
or adapting its implementation. Treat discovered behavior as secondary evidence,
document provenance, and implement independently. Legal review is appropriate
before publishing details derived from deeper reverse engineering.

Apple's current TN3190 also states that macOS Tahoe 26 no longer publishes the
deprecated IOAudioFamily kernel services. That independently closes off the old
kext architecture even apart from its x86_64-only binary.

## 5. Current macOS architecture comparison

### 5.1 Direct AudioDriverKit + USBDriverKit — recommended product path

Apple says [AudioDriverKit](https://developer.apple.com/documentation/audiodriverkit)
connects a DriverKit audio extension to HAL without an AudioServerPlugIn. The
driver subclasses `IOUserAudioDriver`; an `IOUserAudioDevice` owns input/output
`IOUserAudioStream` objects, handles `StartIO`/`StopIO`, format changes and zero
timestamps. The current sample explicitly limits AudioDriverKit to physical
devices and says a real device class may communicate with USB hardware.

The same dext should use
[USBDriverKit](https://developer.apple.com/documentation/usbdriverkit) and match
only VID `0x1235`, PID `0x0018`, interface number 0. An
[`IOUSBHostInterface`](https://developer.apple.com/documentation/usbdriverkit/iousbhostinterface)
provider supplies alternate-setting, endpoint control, frame number and pipe I/O.
Matching the interface rather than the whole device is important: interface 1
must remain available to the stable controller bridge.

Advantages:

- Apple's current physical-audio architecture;
- no HAL plug-in process, custom IPC protocol or shared-memory boundary;
- direct HAL lifecycle, stream buffer and timestamp APIs;
- user-space driver isolation on Intel and Apple silicon;
- one owner for Twitch audio state and USB frame timing.

Costs/constraints:

- a containing app and System Extensions activation UX;
- full Xcode, signing and provisioning;
- `com.apple.developer.driverkit`, DriverKit Audio Family, USB transport and
  user-client entitlements as required by the final design;
- Apple's approval for distribution entitlements. Apple's
  [entitlement guidance](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)
  says the complete entitlement group must be requested together;
- DriverKit C++ and real-time/lifecycle testing are new project surfaces.

### 5.2 AudioServerPlugIn + USB owner — supported fallback

Apple's plug-in+dext sample remains supported and demonstrates device discovery,
IPC and 44.1/48 kHz audio objects. A USBDriverKit dext would own interface 0,
while an AudioServerPlugIn loaded by `coreaudiod` would publish the device and
exchange samples/state through bounded shared memory or user-client calls.

This is appropriate only if AudioDriverKit cannot attach to the required
interface/provider or lacks a needed transport/timing facility in practice. It
adds two components, an IPC ABI, ring synchronization, two failure domains and
more installation state. It should not be chosen merely because older open-source
HAL plug-in examples are plentiful.

### 5.3 App-hosted IOUSBHost/libusb — recommended research transport only

The existing Swift package has already proven logged-in-user `IOUSBHost` device
and interface access on this Mac. Apple's
[`IOUSBHostPipe`](https://developer.apple.com/documentation/iousbhost/iousbhostpipe)
supports scheduled asynchronous isochronous frame lists. This makes IOUSBHost the
smallest A1 base: no driver install, no security changes, no Core Audio object and
maximum reuse of descriptor discovery/state recording already in this repository.

`libusb` is a viable diagnostic fallback. It has a mature macOS backend,
asynchronous isochronous transfers and LGPL-2.1-or-later licensing when dynamically
linked. It is not preferred for A1 because it adds a dependency and changes the
proven ownership layer without solving a Twitch-specific problem.

Neither app-hosted mechanism is the final always-available Core Audio transport.

## 6. Reusable implementations and licenses

This repository currently has no top-level license. Choose one before copying any
third-party code. The following review records repository heads observed on
2026-08-10; pin and re-audit before actual reuse.

| Candidate | Observed revision | License | Reusable value | Limit |
|---|---|---|---|---|
| [Apple SimpleAudioDriver / AudioDriverKit sample](https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver) | current documentation/sample | [Apple Sample Code License](https://developer.apple.com/support/downloads/terms/apple-sample-code/Apple-Sample-Code-License.pdf) | authoritative audio objects, stream memory, I/O callbacks, sample-rate changes, zero timestamps, containing-app/dext structure | sample is timer/loopback based, not USB; entitlements still required |
| [Apple AudioServerPlugIn + dext sample](https://developer.apple.com/documentation/coreaudio/building-an-audio-server-plug-in-and-driver-extension) | current documentation/sample | Apple Sample Code License | fallback HAL object and IPC design | extra component boundary; no longer necessary when AudioDriverKit works |
| [djm-t1-driver](https://github.com/yuki-ama/djm-t1-driver) | `90c09d72bd6f6b5cbe218fe73e4b76f31cfd9061` | MIT; dynamically linked libusb LGPL-2.1+; vendored libASPL MIT | closest public non-class DJ-audio example: bounded isoch engine, bridge lifecycle, shared rings, HAL integration, test harness | different USB protocol; root daemon; legacy AudioServerPlugIn; fixed packet assumptions must not be copied to Twitch |
| [libASPL](https://github.com/gavv/libASPL) | `633e0f70203edd87d320fc5a3cae901e1363aac5` | MIT | mature AudioServerPlugIn object/property boilerplate and real-time patterns | useful only for fallback ASP architecture, not AudioDriverKit |
| [BlackHole](https://github.com/ExistentialAudio/BlackHole) | `5ed63f061e52d7390bf107a3a300ed085a681c9c` | GPL-3.0; separate brand restrictions | mature virtual HAL plug-in and timing/ring ideas | copyleft, virtual only, no USB; incompatible with a non-GPL distribution unless separately licensed |
| [libusb](https://github.com/libusb/libusb) | `daedf276c38a544dba86d408a930fa8983c42f00` | LGPL-2.1-or-later | portable A1 isochronous fallback | dependency and macOS ownership differences; dynamic-link compliance required |
| Local Linux `snd-usb-audio` source | commit `db2ddb87143519e20a95aa36c60b36107b736a58` | GPL-2.0-or-later files | protocol oracle, packet/feedback algorithms and error cases | behavior may be reimplemented; copied code imposes GPL obligations |
| Historical Novation binaries | 2.7 and 3.1.699 | proprietary/no adaptation grant found | static behavior and constants only | no code reuse; never install or execute |

Recommended reuse is therefore mostly Apple framework/sample structure plus
independently implemented Twitch transport. If the AudioServerPlugIn fallback is
required, libASPL and the DJM-T1 project are the most directly reusable permissive
bases.

## 7. Product component boundaries

### 7.1 Reusable framework surface

- AudioDriverKit: HAL publication, device/stream/control object model, stream
  memory, lifecycle and timestamps.
- USBDriverKit: interface-0 matching/ownership, frame clock, endpoint control and
  isochronous transfer submission.
- Apple sample structure: containing app, system-extension activation, audio
  object setup and format changes.
- Existing repository descriptor parser, exact matching, evidence serialization
  and safe state snapshots where portable into the A1 harness.

### 7.2 Twitch-specific implementation surface

- exact `1235:0018`, configuration 1, interface-0 validation;
- alternate 0/1 lifecycle and controller-activation coexistence;
- endpoint sampling-frequency `SET_CUR`/optional `GET_CUR`;
- four-channel packed-24 conversion and interleaving;
- per-USB-frame packet sizing and queued-frame scheduling;
- `0x82` role detection and clock/feedback discipline;
- physical output channel labels and routing;
- later capture unpacking/channel semantics;
- rate-change, underrun/overrun, discontinuity, unplug and sleep/wake recovery;
- Core Audio zero timestamp, latency and safety-offset model tied to measured USB
  frames rather than a wall-clock guess.

### 7.3 Stable controller coexistence

The audio owner must match and open only interface 0. It must never open `0x03` or
`0x84` and must not publish MIDI.

For A1, start the existing controller bridge first so its proven `0 -> 1 -> 0`
activation completes and it retains only interface 1. A1 then owns interface 0.
Verify controller input/output throughout without adding interface-1 access to
the audio harness.

For the future dext, selecting interface 0 alternate 1 inherently performs the
transition that activates controller transport. If the audio dext already owns
interface 0 when the controller bridge starts, the bridge's current activation
attempt may be refused. That is a predicted ownership conflict, not yet measured.
Only after reproducing it should controller startup be changed to tolerate an
already-active/busy interface 0 and proceed with interface 1.

## 8. Staged plan

### A1 — bounded userspace playback proof

Use IOUSBHost only. Claim interface 0, validate rate setup, characterize `0x82`,
send bounded silence, then low-level one-channel-at-a-time tones if all gates pass.
No Core Audio device.

Gate: repeatable clean silence/tone runs, identified four-channel output map,
understood packet-sizing input, zero unexplained transfer errors, safe shutdown,
and controller coexistence.

### A1.5 — sustained playback/clock validation

Stream generated and file-backed audio for 30 minutes at 48 kHz, then 44.1 kHz.
Measure requested/completed frames, feedback or capture cadence, drift,
underruns, discontinuities and reconnect. Establish the exact rate-change order.

Gate: quantified clock model and bounded recovery behavior at both rates.

### A2 — capture characterization

Read `0x82` as an audio stream only after A1 evidence supports that
interpretation. Determine word width/packing, channels, rate coupling and
mic/aux/direct-monitor semantics with loopback and known signals.

Gate: objective input format/channel map and stable full-duplex run. Playback-only
Core Audio could proceed earlier if capture remains unresolved and is explicitly
omitted from v1.

### A3 — AudioDriverKit prototype

Obtain/install full Xcode, create a containing app plus an AudioDriverKit dext,
add USBDriverKit interface-0 transport, and publish four playback channels at the
proven rates. Initially omit input if A2 is not complete.

Gate: Audio MIDI Setup and Mixxx see a stable physical device; master/cue routing,
timestamps, latency, rate changes, unplug and controller coexistence pass.

### A4 — product hardening and distribution

Request the complete Apple entitlement group, sign/notarize, implement install,
upgrade/uninstall, sleep/wake, multi-client, overload diagnostics and long-run
tests. Add capture only if A2 passed.

Gate: repeatable installation on a clean Apple-silicon Mac without disabling
security controls.

## 9. Exact proposed A1 test

A1 is a new executable milestone and requires separate authorization after this
document is reviewed. It must not alter the M0-M4 controller code.

### 9.1 Preconditions

1. Warn the operator to turn master, booth and headphone levels down and remove
   headphones before tones.
2. Start the current controller bridge first; confirm PLAY input and one LED
   update work.
3. Match exactly one `0x1235:0x0018`; reject ambiguity or any descriptor change.
4. Record device/configuration, both alternates, endpoint inventory, registry
   identity, ownership/busy state and current alternate settings.
5. Refuse unless configuration is 1, interface 0 is alternate 0, and the two
   measured isochronous endpoints match direction/type/max packet/interval.

### 9.2 Claim and initialize only interface 0

1. Open interface 0 with IOUSBHost without reset, device capture, configuration
   change or interface-1 access.
2. Select alternate 1 and verify it.
3. Issue only the Linux-established endpoint-class 48 kHz `SET_CUR` above.
4. Attempt the standard three-byte `GET_CUR`; log failure/mismatch but do not
   retry indefinitely or substitute a vendor request.
5. Obtain current USB frame/time and schedule all isochronous requests against
   future frame numbers. Maintain a small bounded queue rather than completion-
   time resubmission alone.

### 9.3 Characterize `0x82` without assumptions

Before interpreting clocking, submit a bounded set of IN frame requests with
buffers sized from the descriptor (294 bytes). Record per frame:

- requested and completed lengths;
- status and timestamp;
- bounded raw bytes and hash;
- cadence relative to USB frame numbers.

Classify only after observation:

- repeated 3/4-byte values near the nominal full-speed feedback rate support
  explicit feedback;
- 264/270 or 288/294-style frame-aligned payloads support an audio/implicit
  stream hypothesis;
- zeros, mixed lengths or content without a stable interpretation remain
  unknown.

Optionally reproduce Linux's four-byte request in a separate bounded subtest only
after the full-size observation. Never silently discard or reinterpret excess
data.

### 9.4 Silence gate

Send exactly two seconds of four-channel packed-24 zero samples at 48 kHz on
`0x01`:

- one transfer frame per full-speed USB frame;
- nominal 576-byte packets unless measured valid feedback requires bounded
  47/48/49-frame variation;
- never exceed descriptor max 588;
- queue 8-16 ms ahead with a fixed maximum outstanding count;
- run `0x82` observation concurrently if it is required for clock evidence;
- log every frame request/completion and stop on the first persistent scheduling,
  stall, overrun, underrun or device-removal error.

The tone phase is prohibited unless silence completed, all requests drained, no
USB error occurred, packet counts remain frame-aligned, and controller I/O still
works.

### 9.5 Low-level channel-map gate

After an explicit terminal confirmation, play a 440 Hz sine at no more than
`-48 dBFS`, with 10 ms ramps, for one second on each channel 1 through 4, separated
by one second of silence. Ask the operator to identify master left/right,
headphone/cue left/right, booth behavior, silence, swaps or duplication. Do not
raise level automatically. Abort immediately on request or any USB error.

### 9.6 Shutdown and artifacts

On completion, Ctrl-C or unplug:

1. stop accepting work;
2. abort/cancel IN and OUT frame lists once, then wait boundedly for completions;
3. send no more audio/control requests;
4. select interface 0 alternate 0 if the device remains present;
5. destroy/release interface ownership;
6. record post-state and verify interface 1/controller remains healthy;
7. preserve metadata, raw bounded `0x82` evidence, per-frame JSONL, generated
   signal specification, operator channel observations and a summary under
   `captures/`.

No vendor request, reset, configuration change, controller endpoint access,
Core Audio publication, DriverKit installation or legacy binary execution is part
of A1.

## 10. Remaining clock and synchronization questions

- A1.5 establishes that `0x82` follows exact audio-frame-sized cadence at both
  rates rather than 3/4-byte explicit feedback, and known MIC/AUX signals prove
  capture semantics and left/right AUX mapping. Exact numeric scaling remains.
- Is `0x82` merely capture on the same device clock, or is its cadence also the
  implicit clock reference that a playback engine should follow?
- Must a production engine establish stable IN cadence before starting OUT, or
  can both schedules start independently as in the successful A1.5 runs?
- Is the device clock synchronous to SOF despite descriptor bits, or free-running?
- A1.5 physically proves constant 576-byte OUT for 30 minutes at 48 kHz and an
  exact 900 × 528 / 100 × 540 cadence per second at 44.1 kHz. Whether a longer
  production run ever requires correction remains a hardening question, not an
  immediate protocol gap.
- Are playback and capture locked to one sample rate and one clock domain?
- How should USB-frame time map to AudioDriverKit `GetZeroTimeStamp`, safety
  offsets and reported latency?
- How many milliseconds must be queued to survive scheduler jitter without
  excessive DJ cue latency?
- Does selecting alternate 0 discard device clock/rate state?

## 11. Revised level-of-effort estimate

Assuming one developer familiar with macOS/USB and ready access to this hardware:

| Work | Estimate |
|---|---:|
| A1 bounded harness and physical channel mapping | 3-7 engineering days |
| A1.5 dual-rate sustained clock validation | 3-7 days |
| A2 capture/full-duplex characterization | 1-2 weeks |
| A3 AudioDriverKit + USBDriverKit playback prototype | 2-4 weeks |
| Capture integration, hardening, installer, sleep/unplug, long runs | 3-6 weeks |

Expected total is roughly **7-13 engineering weeks**, plus Apple entitlement
approval lead time and any clean-Mac test cycles. A playback-only v1 with capture
deferred could land toward the lower end. An unresolved `0x82` clock model or a
forced fallback to AudioServerPlugIn+IPC pushes toward or beyond the upper end.

## 12. Readiness

**A1 COMPLETE: YES. A1.5 COMPLETE: YES.**

**A2 READY: YES. A3 PLAYBACK-ONLY READY: YES.**

The measured basis is recorded in sections 13-14, `A1_STATUS.md`, and
`A1_5_STATUS.md`. Sustained dual-rate scheduling, known-signal capture and
controlled physical routing no longer block progress. Exact capture scaling and
the zero-length-IN lifecycle anomaly remain later-stage engineering questions.

## 13. A1 measured findings

Canonical physical capture:
`captures/20260810T231803.901Z-twitch-a1-audio/`.

### 13.1 Initialization and endpoint role

- The exact endpoint-class 48 kHz `SET_CUR` completed successfully with three
  bytes `80 bb 00`.
- The three-byte `GET_CUR` also completed and returned `80 bb 00`.
- Full-capacity `0x82` observation returned 238 packets of 288 bytes and 12 of
  294 bytes in the canonical 250-frame sample. Other bounded A1 observations
  also produced 282-byte packets. These lengths are exactly 47, 48 and 49
  two-channel packed-24 sample frames.
- Payloads were nontrivial and changed from frame to frame. Together with the
  historical two-input driver evidence, this establishes `0x82` as an
  audio-data-sized input transport, not a 3/4-byte explicit-feedback stream.
  Exact sample semantics and physical inputs remain an A2 measurement.

### 13.2 Playback and timing

- Exactly 2,000 consecutive OUT frames completed at 576 bytes per frame:
  48 samples × 4 channels × 3 bytes, or two seconds at 48 kHz.
- Concurrent `0x82` reads completed 2,000/2,000 frames at 288 bytes with no USB
  status error.
- USB transaction timestamps advanced at a mean of approximately 999.99 µs per
  frame. Across the canonical two-second OUT run, observed intervals ranged
  from approximately 970.8 to 1,026.7 µs; this is transport timestamp variation,
  not an end-to-end latency measurement.
- The fixed rolling queue held 12 transactions with measured scheduling leads
  of 8–19 frames. A single earlier combined seven-second tone run reached a
  one-frame lead after 1,124 frames and correctly aborted on
  `kIOReturnIsoTooOld`. Independently drained one-second
  tone/silence segments then completed cleanly. A1.5 must make the long-running
  queue resilient without silently creating discontinuities.

### 13.3 Physical headphone observations

With headphones connected at low level, MASTER/CUE MIX centered, and the
operator reporting MASTER and monitoring controls slightly above zero:

- USB playback channel 1 was heard in the left ear only;
- channel 2 was heard in the right ear only;
- channel 3 was heard in both ears;
- channel 4 was heard in the right ear only.

These are measured headphone-jack observations under that control state. They
did not establish isolated master/booth/cue routing in A1; A1.5 later repeated
the map at controlled extremes and through external output connections.

### 13.4 Coexistence and shutdown

- The M4 bridge retained exclusive ownership of interface 1 throughout the
  canonical run. PLAY input and its Mixxx-driven LED response were confirmed
  before audio, after silence and after tones.
- Pre/post registry identity, configuration and interface state were unchanged.
  Normal shutdown restored interface 0 from alternate 1 to alternate 0.
- Early development runs exposed a Swift dispatch-executor trap in Ctrl-C prompt
  handling. The final implementation removed Swift dispatch from the signal
  path. A bounded smoke test selected alternate 1, issued no rate or endpoint
  request, received Ctrl-C, and restored alternate 0 without a crash. A second
  smoke test interrupted an active bounded `0x82` frame-list run; the synchronous
  abort completed and alternate 0 was restored.

### 13.5 A1.5 gate

A1.5 may proceed because:

- initialization, four-channel packed-24 playback and concurrent audio-sized IN
  are physically proven at 48 kHz;
- interface ownership coexists with the frozen controller bridge;
- normal and Ctrl-C restoration are physically proven;
- the remaining work is sustained scheduling/clock measurement, 44.1 kHz and
  controlled analog-route characterization—not protocol discovery from zero.

## 14. A1.5 measured findings

Detailed capture provenance, exact distributions and caveats are recorded in
`A1_5_STATUS.md`.

### 14.1 Scheduler policy

The first sustained policy retained only a 16-frame horizon. After 140.556
seconds a measured 18.108 ms completion gap exhausted it; the harness refused a
stale frame before submission. This directly explains the earlier long combined
schedule's `kIOReturnIsoTooOld` risk.

The validated research policy uses eight active batches of eight frames with a
64-frame initial lead and completion-driven refill. This is bounded validation
headroom, not a product latency decision. It completed three minutes, 30 minutes
and ten minutes without a stale frame, retry, `IsoTooOld`, short OUT packet or
USB transaction error. Minimum lead was 28 frames in the 30-minute run and 34
frames in the 44.1 kHz run.

### 14.2 Dual-rate cadence and drift

At 48 kHz, 1,800,000 OUT packets were all 576 bytes. Concurrent IN consisted of
1,799,995 × 288-byte and 5 × 294-byte packets. IN acquired a fixed +5 candidate
audio-frame offset in the first second and retained exactly +5 for every one of
the 1,800 one-second aggregates.

At 44.1 kHz, OUT physically confirmed the phase-accumulator schedule: 540,000 ×
528-byte and 60,000 × 540-byte packets over ten minutes. IN used 540,003 × 264
and 59,997 × 270 bytes. Its fixed -3 candidate-frame offset was present in the
first aggregate and unchanged through all 600 aggregates.

Thus neither sustained run shows accumulated IN/OUT frame drift. Both physically
verified endpoint `SET_CUR` and `GET_CUR` at their requested rates.

### 14.3 Transport timing

Host USB transaction timestamps remained centered near one millisecond:

| Rate/direction | Mean interval | Standard deviation | Observed range |
|---|---:|---:|---:|
| 48 kHz OUT | 999.9906 µs | 4.747 µs | 934.833-1,070.292 µs |
| 48 kHz IN | 999.9906 µs | 4.774 µs | 928.708-1,076.458 µs |
| 44.1 kHz OUT | 999.9909 µs | 4.764 µs | 936.833-1,063.917 µs |
| 44.1 kHz IN | 999.9909 µs | 4.816 µs | 927.500-1,081.708 µs |

These measurements characterize USB transaction timestamp variation only. They
do not establish analog round-trip latency or the final AudioDriverKit safety
offset.

### 14.4 `0x82` confidence boundary

`0x82` is physically established as capture audio and a clock-correlated,
two-channel-audio-frame-sized stream at both supported rates. Known microphone
speech rises and falls with the captured samples; known isolated AUX wiring maps
LEFT to channel 1 and RIGHT to channel 2. Mono microphone input appears on both
channels. Stereo signed packed-24 little-endian is strongly supported, while
exact sample scaling/sign-extension remains A2 work.

### 14.5 Coexistence and remaining physical work

The frozen controller bridge and Mixxx-driven LEDs coexisted through the
three-minute 48 kHz and ten-minute 44.1 kHz runs. They also coexisted for 29m46s
of the 30-minute run; the controller bridge's independent timer expired 14
seconds before audio, so the post-run controller prompt was deliberately not
confirmed. Audio transport still completed and alternate 0 was restored.

Controlled tones establish playback channels 1/2 as MASTER left/right and 3/4 as
CUE left/right. This was reproduced through headphones at both mix extremes,
BOOTH with its source switch at MASTER, and direct balanced MASTER L/R into two
KRK Rokit 5 monitors. Controller input and LED output remained healthy after each
test.

Repeated short interface-0 sessions produced a state in which successful `0x82`
transactions returned zero bytes while OUT remained healthy; a physical replug
restored payload delivery. The ordinary alternate/rate sequence did not recover
it. This lifecycle behavior is measured, but its cause is not established.

## 15. A3 implementation feasibility and boundary

A3 retains the direct physical-device architecture:

`Core Audio HAL -> AudioDriverKit dext -> USBDriverKit interface 0 -> 0x01`

Current Apple AudioDriverKit material explicitly permits a physical audio device
driver to communicate with USB hardware using the appropriate transport
entitlement. USBDriverKit supports custom/non-class-compliant USB devices and an
`IOUSBHostInterface` provider, so Twitch remains in scope. An AudioServerPlugIn
has not been introduced.

The first reusable A3 component is now a framework-neutral C boundary that
accepts four interleaved Float32 channels, applies deterministic clipping, packs
signed 24-bit little-endian samples, implements both proven USB packet cadences,
and uses a bounded ring with visible underrun/overrun accounting. It does not
conflate Core Audio buffering, reported latency or USB scheduling lead.

Xcode 26.6 is now installed and selected. The macOS 26.5 SDK, DriverKit 25.5 SDK,
AudioDriverKit, USBDriverKit and `iig` were verified. The attributed containing
app and playback-only dext scaffold compile unsigned, including exact interface-0
matching, four-channel Float32 stream declarations, USB provider validation,
alt-1/endpoint acquisition and alt-0 restoration. The dext is not yet complete:
rate requests, bounded isochronous submission/cancellation, ring consumption and
unplug hardening remain before activation.

Activation is still externally blocked. Xcode displays an Apple Development
certificate, but the selected Personal Team cannot provision System Extension
or DriverKit capabilities and no DriverKit profiles are present. An eligible
Apple Developer Program team must obtain one complete Apple-approved entitlement
group containing Audio Family, the HAL user-client permission required by the
current sample, and USB transport for `0x1235:0x0018`. The project will not
disable SIP/security checks to bypass that requirement.

**A3 COMPLETE: NO. A4 READY: NO.** See `A3_STATUS.md`.
