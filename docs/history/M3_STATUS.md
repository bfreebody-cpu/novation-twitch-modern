# M3 status: Mixxx integration

Date: 2026-08-10 (America/Toronto)

## Decision

**M3 COMPLETE: YES**

The input-only `Novation Twitch Modern` Core MIDI source was recognized by the
installed Mixxx, loaded the user mapping, and controlled a track. The two
failures demonstrated during live testing - LOAD appearing ineffective and
reversed SWIPE direction - were isolated and retested successfully. The LOAD
test passed after deck A was stopped and manually emptied; SWIPE passed after
the relative jog sign was corrected.

**M4 READY: YES**

The remaining limitations below do not block a separately scoped controller
output/LED milestone. M4 must preserve the proven USB IN and Core MIDI source
path and must not treat the mapping as authority for USB audio.

## Installed Mixxx and mapping location

- Mixxx: 2.5.6, native arm64 application at `/Applications/Mixxx.app`
- Settings root reported by Mixxx:
  `~/Library/Containers/org.mixxx.mixxx/Data/Library/Application Support/Mixxx`
- User controller directory:
  `~/Library/Containers/org.mixxx.mixxx/Data/Library/Application Support/Mixxx/controllers`
- Installed files:
  - `Novation Twitch Modern.midi.xml`
  - `Novation-Twitch-Modern-scripts.js`
- The installed copies are byte-identical to the repository copies. Final
  SHA-256 values are `86f5b3f8b57c53f750abe0d4af3c5075728ce39952b6d352f3e60e4cc9abb89b`
  for the XML and
  `c434e5ecc81ac02d75049e681597bcedd876565b34b4f885838fabd65907b934`
  for the JavaScript.
- The application bundle was not modified.

## Mapping files

Canonical repository files:

- `mapping/novation-twitch-modern/Novation Twitch Modern.midi.xml`
- `mapping/novation-twitch-modern/Novation-Twitch-Modern-scripts.js`
- `mapping/novation-twitch-modern/test-mapping.swift`
- `mapping/novation-twitch-modern/README.md`

The XML identifies the exact Core MIDI source name and loads the JavaScript.
Input handlers are registered by the script, so the XML intentionally has an
empty `<controls/>` element.

## Historical evidence used

The behavioral starting point was the recovered Mixxx 2.3.6 mapping:

- `reference/mixxx/2.3.6/res/controllers/mixco/novation_twitch.mixco.js`
- `reference/mixxx/2.3.6/res/controllers/novation_twitch.mixco.output.js`
- `reference/mixxx/2.3.6/res/controllers/novation_twitch.mixco.output.midi.xml`

The input behavior was reconciled with measured evidence in
`control-inventory/twitch-basic-input.json` and the supplied Novation
Programmer's Reference. Measured channel-10 LOAD messages and undocumented FX
encoder-push events were preserved. Historical output/preinitialization code
was not copied because M3 is input-only.

## Current Mixxx API adaptations

- Replaced the removed Mixco module/loader assumptions with Mixxx 2.5
  `midi.makeInputHandler` registrations and explicit disconnection at shutdown.
- Used current EQ controls
  `[EqualizerRack1_[ChannelN]_Effect1],parameter1/2/3` instead of deprecated
  deck `filterLow`, `filterMid`, and `filterHigh` controls.
- Used `[Skin],show_maximized_library` rather than the deprecated
  `[Master],maximize_library` control.
- Used `[EffectRack1_EffectUnit1],chain_preset_selector` rather than the old
  `chain_selector` name.
- Kept the USB transport and Core MIDI publication completely outside Mixxx.
- Added structured `TWITCH_MODERN` diagnostic records around Mixxx control
  writes without sending MIDI to the Twitch.

Current Mixxx 2.5 documentation and the installed 2.5.6 controller API/type
definitions were treated as implementation authority. The 2.3.6 mapping was
behavioral history, not API authority.

## Live controls verified

The primary live run was captured in Mixxx's rotated `mixxx.log.2`. It contains
no JavaScript syntax error, `TypeError`, or `ReferenceError` from this mapping.

Working end-to-end in the live run:

- Core MIDI source discovery, preset selection, and script initialization
- Deck A and B PLAY and CUE
- Both channel faders and the crossfader, including full-range movement
- Both decks' TRIM controls
- Both decks' HIGH, MID, and LOW EQ controls using the current effect-rack EQ
  groups
- Browse encoder in both directions, including its pushed fast-scroll mode
- BACK and FWD sidebar navigation
- LOAD A in a controlled test with deck A stopped and empty
- Deck A pitch/tempo encoder representative movement
- DROP/play-position behavior
- SWIPE on both touchstrips; the user confirmed the corrected direction
- Touchstrip touch/release events
- HOT CUES representative pads
- AUTO LOOP and LOOP ROLL representative pads
- Quick-effect/filter controls and representative performance-pad behavior
- Master FX DEPTH, MOD/X, BEATS, and ON/OFF input

The physical Master FX `FX SELECT` arrow buttons were measured in the final
short bridge as note 32 then note 33 on MIDI channel 12. The deterministic
mapping test confirms these target Effect Unit 1's deck A and deck B assignment
controls. They were not observed end-to-end after the final Mixxx restart
because Mixxx did not complete MIDI initialization; this is explicitly a
transport-plus-boundary verification, not a claimed final UI observation.

## Demonstrated failures and corrections

### LOAD

Mixxx logs showed both LOAD A and LOAD B actions reaching
`LoadSelectedTrack`, but loading the already-loaded only available track did
not provide an observable UI result. With deck A stopped and manually ejected,
LOAD A loaded the selected track successfully. No mapping change was needed.

LOAD B reached Mixxx during the run but did not receive the same unambiguous
empty-deck test because only one track was available.

### SWIPE direction

The initial historical sign made SWIPE feel reversed on this hardware. The jog
delta changed from `-delta / 3` to `delta / 3`, a regression test was added,
and the user confirmed the corrected behavior live.

### Master FX page buttons

The initial mapping incorrectly treated basic-mode FX PARAMS notes 28-31 as
Mixxx effect-slot buttons. Physical testing of the middle-row `DECK A` and
`DECK B` buttons produced notes 29/30, and the Programmer's Reference confirms
that notes 28-31 select Twitch-local FX parameter pages in basic mode. These
notes now only produce diagnostic records. They no longer modify Mixxx effect
slots. The bottom `FX SELECT` arrows (notes 32/33) retain the historical Mixxx
deck-assignment behavior.

## Partial or unverified behavior

- Only one test track was available. Two-deck mixing and an unambiguous LOAD B
  test were therefore limited.
- Pitch movement was observed on deck A; deck B pitch was not separately
  confirmed in the Mixxx log.
- HOT CUES, AUTO LOOP, and LOOP ROLL were verified representatively, primarily
  on deck A rather than exhaustively on both sides.
- SLICER/performance mode remains a pragmatic partial adaptation of the
  historical mapping: sampler preview and spinback behavior were observed, but
  every performance-pad function was not validated against loaded sampler
  content.
- Controller output, LEDs, advanced mode, Twitch audio, and Mixxx source-code
  changes remain outside M3.

## Logs, errors, and lifecycle observations

- The underlying bridge evidence was preserved in
  `captures/20260810T201727.831Z-twitch-m2-bridge/` for the primary run and
  `captures/20260810T205007.314Z-twitch-m2-bridge/` for the short final USB
  verification. The directory names reflect the reused M2 bridge executable;
  no M2 implementation was changed for M3.
- No USB, Core MIDI delivery, or MIDI parser errors occurred during the primary
  successful Mixxx run.
- Mixxx logged `PortMIDI device "Novation Twitch Modern" already closed` once
  while the controller settings were changed. It did not recur during normal
  control use.
- Hot-reloading the installed script logged file-watcher warnings but performed
  a clean mapping shutdown and re-initialization each time.
- Exercising the historical spinback performance-pad behavior caused Mixxx
  warnings that scratch timer 0 did not exist. Mixxx continued processing input;
  this is retained as a partial performance feature rather than hidden.
- When the bounded bridge exited and a new virtual source with the same name was
  created, the running Mixxx process did not attach to the new endpoint. A later
  Mixxx relaunch stalled in its HID discovery phase before MIDI initialization.
  The relaunch was then quit cleanly. The established operating order is to
  start the bridge before Mixxx and restart Mixxx if the virtual source process
  is replaced.
- The final short bridge saw one bounded parser warning at startup: bytes
  `9b 00` formed an incomplete message before a new status byte. This is
  consistent with joining a device byte stream at a message boundary after
  reactivation; all subsequent messages, including notes 32/33, decoded in
  order without residual corruption. The proven M2 USB code was not changed.
- Both bridge runs restored/released USB state on bounded timeout or Ctrl-C.

## Tests

All final checks passed:

- `swift build -c debug`
- `swift run -c debug twitch-parser-tests`
- `swift mapping/novation-twitch-modern/test-mapping.swift`
- XML validation with `xmllint`
- static scan proving the production mapping contains no `midi.send*` call
- repository and installed mapping hashes match

The deterministic mapping test covers current control names, PLAY/CUE,
crossfader, EQ, browse, measured LOAD behavior, HOT CUES, loops, FX selection,
the corrected SWIPE sign, hardware-only FX parameter pages, handler teardown,
structured diagnostics, and the no-output boundary.

## Additional project reference

`reference/TWITCH_PANEL_CONTROLS.md` now records the physical panel labels and
locations from the supplied user guide. Documented labels remain separate from
measured MIDI identities. Poppler was installed with prior user authorization
to inspect the manual's panel diagrams; no supplied PDF was modified.
