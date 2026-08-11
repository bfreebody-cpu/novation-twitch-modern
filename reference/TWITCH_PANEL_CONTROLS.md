# Novation Twitch panel control labels

This is a transcription/index of the labels printed on the physical Novation
Twitch. Its source is the supplied *Novation Twitch User Guide*,
`docs/novationtwitchmanualen.pdf`, especially PDF pages 13-18. It records
documented hardware labels only; it is not evidence that a control was observed
on USB or that the current Mixxx mapping implements it.

## Browse (top center)

- `SCROLL` rotary encoder with push
- `BACK`
- `FWD`
- `AREA`
- `VIEW`
- `LOAD A`
- `LOAD B`

## Mixer controls (one set per deck unless noted)

- Deck channel fader
- `TRIM`
- `HIGH`
- `MID`
- `LOW`
- Headphone Cue select (headphone-symbol button)
- `FADER FX` rotary encoder with push
- `FX ON/OFF`
- Crossfader (shared)

## Master and monitoring

- Master Headphone level (headphone-symbol knob)
- `MIX` (headphone Master/Cue balance)
- `BOOTH`
- `MASTER`

These are hardware audio/monitoring controls and are not all controller MIDI
inputs. Do not confuse the headphone `MIX` knob with a Master FX parameter.

## Deck controls (one set per deck)

- Play/pause (play/pause-symbol button)
- `CUE`
- `KEYLOCK`
- `SYNC/AUTO`
- `PITCH` rotary encoder with push-and-turn coarse adjustment
- `SWIPE`
- `DROP`
- Touchstrip
- `HOT CUES`
- `SLICER`
- `AUTOLOOP`
- `LOOP ROLL`
- Eight performance pads
- `BEAT GRID SET/CLR`
- `BEAT GRID ADJUST/SLIP`
- `SHIFT`

The hardware has Deck A and Deck B control sections. It has no Deck C or Deck D
buttons.

## Master FX (far upper-left block)

Top row, left to right:

- `DEPTH` rotary control
- `MOD/X` rotary encoder with push-and-turn function
- `BEATS` rotary control

Middle row, left to right:

- `AUX`
- `DECK A`
- `DECK B`

Bottom row, left to right:

- `FX SELECT` left arrow
- `FX SELECT` right arrow
- `ON/OFF`

The manual describes `DEPTH` as effect amount, `MOD/X` as one or two
effect-specific parameters, `BEATS` as effect beat base, the three assignment
buttons as AUX/Deck A/Deck B targets, and the two `FX SELECT` buttons as effect
selection. Deck A plus Deck B assigns the original Itch effect to the master.

## Mic/Aux (right side)

- `LEVEL`
- Headphone Cue select (headphone-symbol button)
- `ON/OFF`

## Front-panel controls/connectors

- Mic input
- Mic gain
- 1/4-inch and 3.5-mm headphone sockets

## Terminology cautions for this project

- The physical channel input-gain knobs are labeled `TRIM`, not `GAIN`.
- The touchstrip mode button is labeled `SWIPE`; it is not a “swipe pad.”
- The physical Master FX controls are `DEPTH`, `MOD/X`, and `BEATS`. Historical
  Mixxx mapping comments describe their software targets as effect mix, super
  parameter, and effect selection; those software names are not panel labels.
- `MIX` is the headphone Master/Cue balance in the Master section.
- The `MASTER` monitoring block is at the far upper-right. The separate
  `MASTER FX` block is at the far upper-left, immediately left of `MIC / AUX`.
- Values and MIDI identities belong in
  `control-inventory/twitch-basic-input.json`; this note deliberately does not
  infer them from labels.

## Current Mixxx mapping semantics

These are implementation decisions verified during the controller-v1 closure,
not additional claims from the user guide:

- The physical `SHIFT` button toggles the Twitch's alternate basic-mode page.
  That page emits MIDI channels 10/11 for the physical deck A/B sections; it
  does not imply that the panel has deck C/D selector buttons.
- `BEAT GRID SET/CLR` maps to Mixxx quantize.
- Normal `BEAT GRID ADJUST/SLIP` performs beatgrid alignment; on the SHIFT page
  it toggles Mixxx Slip.
- The SLICER page retains the historical Mixxx compatibility actions because
  Mixxx 2.5.6 has no generic native slicer control: pads 1-4 sampler preview,
  pad 5 spinback, pad 6 brake, pads 7-8 reserved.
- CUE feedback follows Mixxx `cue_indicator`, including the user's configured
  cue-mode blink behavior.
