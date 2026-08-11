# Novation Twitch Modern controller v1 status

Date: 2026-08-11 (America/Toronto)

## Decision

**CONTROLLER V1 COMPLETE: YES**

The supported controller path is:

`Twitch interface 1 <-> IOUSBHost <-> Core MIDI <-> Mixxx 2.5.6`

The bridge uses the measured interface-0 `0 -> 1 -> 0` activation transition,
then reads interrupt IN endpoint `0x84` and writes only documented basic-mode
messages to interrupt OUT endpoint `0x03`. It does not use advanced mode,
vendor-specific requests, or either audio endpoint.

## Functional result

- Bidirectional Core MIDI endpoints are both named `Novation Twitch Modern` and
  have stable unique IDs.
- The current Mixxx mapping has 101 state-output connections.
- PLAY, CUE, PFL, FADER FX, quantize/SET-CLR, keylock, sync, loops, hot cues,
  MASTER FX, beatgrid ADJUST, and SHIFT-page Slip feedback were physically
  verified on both decks.
- Normal and SHIFT-page state feedback is coherent. SHIFT toggles the alternate
  page; it is not a physical deck C/D selector.
- Normal Mixxx quit physically clears the mapped LEDs. Relaunching Mixxx with
  the bridge running republishes current states.
- The deterministic mapping and MIDI/USB parser tests pass.

Exact physical-control semantics and known compatibility behavior are recorded
in `mapping/novation-twitch-modern/README.md`. Machine-readable observed versus
documented evidence is in `control-inventory/twitch-basic-input.json`,
`control-inventory/twitch-basic-output.json`, and
`control-inventory/controller-v1-led-verification.json`.

## Lifecycle result

The primary closure capture is
`captures/20260811T175453.469Z-twitch-m4-bridge/`:

- 4,889 USB IN completions and 1,662 decoded input events;
- 2,053/2,053 Core MIDI output events accepted;
- 1,758/1,758 USB OUT transfers successful;
- maximum OUT transfer 8 bytes;
- no Core MIDI error, USB OUT error, or queue rejection.

Physical removal ended the pending IN operation once with `device not
responding`; the bridge stopped without retry, synchronously aborted output,
and left both interfaces idle at alternate 0.

The reconnect/final-shutdown capture is
`captures/20260811T181502.652Z-twitch-m4-bridge/`:

- 5,454 USB IN completions and 1,845 decoded input events;
- 1,473/1,473 Core MIDI output events accepted;
- 1,147/1,147 USB OUT transfers successful;
- no Core MIDI error, USB output error, or queue rejection;
- Ctrl-C cleanup completed with interface 0 already at alternate 0.

Mixxx 2.5.6 does not hot-discover virtual endpoints recreated after physical
removal. The supported recovery sequence is: reconnect Twitch, restart bridge,
then restart Mixxx. Mixxx retains the mapping and reconnects without manual
controller reconfiguration.

## Known behavior and deferred features

- Hot cues are track metadata in Mixxx. Loading the same track on both decks
  intentionally gives shared cue state.
- SHIFT-page AUTOLOOP begins at 1/32 beat, so its first pads sound extremely
  fast by design.
- CUE follows Mixxx `cue_indicator`; blink behavior depends on Mixxx cue mode.
- SLICER is the historical compatibility page, not a native slicer: pads 1-4
  sampler preview, pad 5 spinback, pad 6 brake, pads 7-8 reserved.
- Touchstrip light guides, meters, richer FX visualization, dim inactive colors,
  and Mic/Aux feedback are optional post-v1 work listed in `TODO.md`.

## Scope boundary

The controller implementation is the stable v1 baseline. Audio research and
the unsigned AudioDriverKit prototype remain separate. No Core Audio device is
installed or published by controller v1.
