# M4 status: controller output and LED feedback

Date: 2026-08-10 (America/Toronto)

## Decision

**M4 COMPLETE: YES**

## Controller-v1 closure addendum (2026-08-11)

M4's original 40-state proof below remains the historical milestone record.
Subsequent bounded polish closed controller v1 at 101 Mixxx state connections:
both-deck state parity, normal and SHIFT-page mirrors, MASTER FX enable, normal
beatgrid ADJUST, persistent SHIFT-page Slip, normal-quit LED clearing, restart
state publication, and physical disconnect/reconnect recovery were all verified.

The closure evidence and current behavior are recorded in
`CONTROLLER_V1_STATUS.md` and
`control-inventory/controller-v1-led-verification.json`. The two live captures
are `captures/20260811T175453.469Z-twitch-m4-bridge/` and
`captures/20260811T181502.652Z-twitch-m4-bridge/`. No advanced-mode, audio, or
vendor-specific traffic was introduced.

The bidirectional controller path is proven:

`Mixxx 2.5.6 -> Core MIDI destination -> documented MIDI 1.0 basic-mode output -> IOUSBHost interrupt OUT 0x03 -> Twitch LEDs`

It operates simultaneously with the established Twitch input path. Advanced
mode was neither required nor used. Twitch audio remains untouched and outside
this milestone.

## Baseline commit

Before M4 work, the complete reviewed M0-M3 tree was committed as:

- `2888bb4 Complete Twitch M0-M3 support and evidence`

No M0-M3 work was discarded.

## Output protocol reconciliation

The machine-readable reconciliation is
`control-inventory/twitch-basic-output.json`. It separates:

- documented Novation messages and intensity/color encodings;
- historical Mixxx 2.3.6 behavior;
- current Mixxx 2.5 controls;
- physical M4 observations; and
- deferred visual polish.

The supplied Programmer's Reference establishes that button LEDs use their
matching note/channel. Single-color intensity is 0-16; bicolor LEDs use the low
four bits for intensity and color offsets red `0x00`, amber `0x40`, and green
`0x70`. M4 uses documented off `0`, full red `15`, full amber `79`, full green
`127`, and full single-color `16`.

The recovered 2.3.6 mapping supplied historical color choices and loop-pad
behavior. Its advanced-then-basic preinitialization sequence was not copied.
Basic mode already provides every M4 functional target, while advanced mode
changes control-surface behavior and had no demonstrated necessity.

Current Mixxx implementation authority was its installed 2.5.6 API plus the
current MIDI scripting and controls documentation. The mapping uses
`engine.makeConnection(...).trigger()/disconnect()` and `midi.sendShortMsg`.

## Core MIDI destination

- Name: `Novation Twitch Modern`
- API: `MIDIDestinationCreateWithProtocol`
- Protocol: `kMIDIProtocol_1_0` / MIDI 1.0 UMP
- Creation/enumeration: successful by exact endpoint and name
- Source stable unique ID: `0x54574D31` (`TWM1`)
- Destination stable unique ID: `0x54574D32` (`TWM2`)

`CoreMIDIVirtualDestination` is separate from the Mixxx mapping, MIDI output
policy/packetizer, and USB writer. It walks each `MIDIEventList`, reconstructs
logical MIDI 1.0 messages with `MIDIUMPStreamDecoder`, and records accepted or
rejected events and API errors.

The safety policy rejects messages outside documented basic output, including
advanced/global CC 0 commands, SysEx, system messages, unknown controls, and
basic-mode FX PARAMS notes 28-31.

## USB output implementation

- Interface: 1
- Alternate setting: 0
- Endpoint: interrupt OUT `0x03` only
- Runtime descriptor-derived maximum packet size: 8 bytes
- Queue: ordered FIFO, maximum 256 packets
- Outstanding writes: one
- Overflow policy: reject the new batch; never drop/reorder accepted packets
- Error policy: no retry; stop, discard unsent queued packets, and clean up
- Shutdown: stop accepting, cancel/abort pipes synchronously, destroy interface

Logical MIDI messages are flattened into a byte stream and packed into writes of
at most the descriptor maximum. USB transfer boundaries are not treated as MIDI
message boundaries. Tests explicitly reject audio endpoints `0x01`/`0x82`, IN
endpoint `0x84`, and every non-`0x03` output target.

## Stage A: first documented physical LED command

Capture:
`captures/20260810T213533.964Z-twitch-m4-led-test/`

- `97 17 7f`: USB success, 3/3 bytes; user confirmed left PLAY illuminated green.
- `97 17 00`: USB success, 3/3 bytes; user confirmed left PLAY extinguished.
- Queue at shutdown: 0 queued, 0 in flight, 0 rejected.
- Interface 0 remained alternate 0; before/after interface busy state was 0.
- No Core MIDI destination was present in this conservative stage.

## Mixxx mapping and feedback

Canonical and installed mapping files:

- `mapping/novation-twitch-modern/Novation Twitch Modern.midi.xml`
- `mapping/novation-twitch-modern/Novation-Twitch-Modern-scripts.js`
- `~/Library/Containers/org.mixxx.mixxx/Data/Library/Application Support/Mixxx/controllers/Novation Twitch Modern.midi.xml`
- `~/Library/Containers/org.mixxx.mixxx/Data/Library/Application Support/Mixxx/controllers/Novation-Twitch-Modern-scripts.js`

Repository and installed copies are byte-identical. The application bundle and
Mixxx source were not modified.

The current mapping has 40 output state connections:

- Deck A/B PLAY: `play_indicator`, full green
- Deck A/B CUE: `cue_indicator`, full red
- Deck A/B general loop active: `loop_enabled`, AUTO LOOP button full green
- Deck A/B hot cues 1-8: `hotcue_N_enabled`, full amber
- Deck A/B AUTO LOOP sizes 0.5/1/2/4/8/16/32/64:
  `beatloop_*_enabled`, matching pads full green
- Effect Unit 1 deck-A/deck-B assignment: documented FX notes 32/33, full intensity

The first live test showed that general loop-active indication worked but the
selected numbered pad did not light because size-specific output was absent.
The historical/current `beatloop_*_enabled` connections were added, tested, and
the user then confirmed that the selected pad illuminated green and turned off
when disabled.

Physically confirmed on deck A: PLAY, CUE, hot cue, general loop active, selected
loop-size pad, and representative MASTER FX assignment. The user reported that
controller input continued to affect Mixxx while LEDs followed state. Deck-B
messages and initialization were delivered, but an equivalent visual pass is
deferred rather than inferred.

## Robustness evidence

Primary simultaneous input/output and disconnect capture:
`captures/20260810T221212.613Z-twitch-m4-verify/`

- 2,369 USB IN completions
- 816 decoded input records
- 203/203 Core MIDI output events accepted
- 178 USB OUT transfers, all successful
- maximum USB OUT transfer: 8 bytes
- 0 Core MIDI errors
- 0 USB OUT errors
- 0 rejected queue packets
- queue empty with no transfer in flight at shutdown

The operator rapidly pressed PLAY while moving continuous controls. Fragmented
input, Mixxx state callbacks, and LED output remained ordered. One parser warning
occurred before that stress sequence: immediately after activation the listener
joined an incomplete startup fragment `97 00`. The next status caused the tested
parser to report/discard those two bytes and recover. There was no residual state
or later corruption; this is recorded evidence, not silently accommodated.

On physical removal, the pending IN request returned `device not responding`.
The process stopped once, synchronously aborted OUT, emitted no retry traffic,
finalized its capture, and did not crash or use stale objects. The terminating
registry identity remained briefly observable with both interfaces idle at
alternate 0, so restoration required no `SET_INTERFACE`.

Process-restart capture after reconnect:
`captures/20260810T221528.753Z-twitch-m4-verify/`

- fresh discovery/activation/interface open succeeded;
- 132/132 Core MIDI output events were accepted;
- 101/101 USB OUT writes succeeded;
- 175 IN completions and 58 decoded events were recorded;
- 0 Core MIDI errors, USB OUT errors, queue rejection, or parser warning;
- Ctrl-C synchronously aborted both paths and left interface 0 at alternate 0.

Stable endpoint IDs let Mixxx retain its enabled mapping across ordinary launches.
Mixxx 2.5.6 still did not hot-reattach while running after the endpoint process
was recreated. Restarting Mixxx restored both directions and initialized all 40
states automatically. This is the supported disconnect recovery policy.

A normal Mixxx quit stopped output and left the bridge stable. That quit did not
record the mapping `shutdown` callback or its individual LED-clear sends in the
Mixxx log. Deterministic tests verify teardown/clearing when the callback is
invoked; the application-quit logging difference is retained as a visual-polish
TODO rather than misreported as observed clearing.

## Tests

All final checks pass:

- `swift build`
- `swift run twitch-parser-tests`
- `swift mapping/novation-twitch-modern/test-mapping.swift`
- JSON validation of the output inventory and all M4 captures
- repository/installed mapping SHA-256 equality

Tests cover MIDI 1.0 UMP reconstruction, documented output allowlisting,
advanced/SysEx/unknown-message rejection, stream packetization across MIDI
boundaries, 8-byte limits, FIFO ordering, overflow rejection, endpoint-`0x03`
enforcement, explicit audio/IN endpoint rejection, 40 current Mixxx state
connections, exact colors/notes, initialization, and teardown.

## Discrepancies and deferred work

- No contradiction with the Programmer's Reference was observed.
- Unlike the historical mapping, inactive LEDs are off rather than dim and M4
  never performs an advanced-to-basic mode cycle.
- The general AUTO LOOP button as `loop_enabled` is an intentional modern
  addition; historical behavior primarily indicated the selected size pad.
- Mixxx `cue_indicator` blinked the CUE LED at roughly two updates per second in
  the tested stopped/cue state. It was stable and documented but remains a UX
  choice for later polish.
- Meters, touchstrip light guides, remaining buttons, page/deck visualization,
  brightness/color refinement, and deck-B visual parity are listed in `TODO.md`.

## Files created or modified for M4

- `ARCHITECTURE.md`
- `M4_STATUS.md`
- `TODO.md`
- `control-inventory/twitch-basic-output.json`
- `Sources/TwitchProbeCore/TwitchBasicOutput.swift`
- `Sources/TwitchParserTests/main.swift`
- `Sources/TwitchM1A/CoreMIDIVirtualDestination.swift`
- `Sources/TwitchM1A/USBControllerOutput.swift`
- `Sources/TwitchM1A/M4Models.swift`
- `Sources/TwitchM1A/M4Output.swift`
- `Sources/TwitchM1A/ControllerListener.swift`
- `Sources/TwitchM1A/CoreMIDIVirtualSource.swift`
- `Sources/TwitchM1A/M1Discovery.swift`
- `Sources/TwitchM1A/M1Models.swift`
- `Sources/TwitchM1A/RunRecorder.swift`
- `Sources/TwitchM1A/main.swift`
- `Package.swift` (adds the `twitch-m4` executable product name)
- the three canonical mapping files and mapping README
- five preserved M4 capture directories under `captures/`
- byte-identical user-level Mixxx mapping copies outside the repository

## Scope confirmation

- Advanced mode: **not used**
- Controller OUT endpoint `0x03`: **used only for documented allowlisted output**
- Controller IN endpoint `0x84`: **preserved**
- Audio endpoints `0x01` and `0x82`: **not opened or accessed**
- Vendor-specific USB requests: **none**
- Core Audio / Twitch audio development: **not started**

**M4 COMPLETE: YES**

The next appropriate work is a separately reviewed controller visual-polish or
packaging/lifecycle milestone. This decision does not authorize Twitch audio work.
