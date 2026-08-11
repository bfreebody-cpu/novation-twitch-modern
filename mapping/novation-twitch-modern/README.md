# Novation Twitch Modern Mixxx mapping

This is the canonical bidirectional Mixxx 2.5.6+ mapping for the Core MIDI
source and destination `Novation Twitch Modern` created by this repository's
M4 bridge mode.

Install both mapping files in the `controllers` directory inside the Mixxx
settings directory. On the sandboxed macOS build used for M3 this is:

```text
~/Library/Containers/org.mixxx.mixxx/Data/Library/Application Support/Mixxx/controllers
```

In Mixxx Preferences > Controllers, select `Novation Twitch Modern`, enable it,
and choose the `Novation Twitch Modern` mapping.

Start `swift run twitch-m4 --mode m4-bridge` (or the already-built
`.build/debug/twitch-m4 --mode m4-bridge`) before launching Mixxx. The M4
source and destination use stable Core MIDI unique IDs, so Mixxx remembers the
enabled mapping across normal bridge/Mixxx launches. A running Mixxx process
still does not hot-reattach after physical removal causes the bridge to exit;
restart the bridge, then restart Mixxx. This is an application endpoint-lifetime
issue, not a reason to change the USB path.

The script uses Mixxx 2.5's `midi.makeInputHandler` for input and
`engine.makeConnection` plus `midi.sendShortMsg` for documented basic-mode LED
feedback. It does not send SysEx, global LED diagnostics, or mode changes.

## Controller-v1 behavior

The mapping publishes 101 Mixxx state connections. PLAY, CUE, headphone/PFL,
FADER FX, SET/CLR, KEYLOCK, SYNC, loop, hot-cue, and MASTER FX LEDs have been
physically verified on both decks. The physical `SHIFT` button toggles the
Twitch's alternate basic-mode page; it is not a hold modifier. Press it again
to return to the normal page. Stateful feedback is mirrored onto that page so
lights do not disappear merely because the page changed.

- `BEAT GRID SET/CLR` toggles Mixxx quantize and its LED follows that state.
- Normal-page `BEAT GRID ADJUST/SLIP` aligns the beatgrid and lights only while
  pressed. On the SHIFT page it toggles Mixxx Slip and its LED follows Slip.
- HOT CUES pads select or set cues. On the SHIFT page the same pads clear them.
  If the same track is loaded into both decks, its hot cues are shared track
  metadata, so clearing one also changes the other deck's display.
- Normal AUTOLOOP pads select 0.5, 1, 2, 4, 8, 16, 32, or 64 beats. SHIFT-page
  AUTOLOOP pads select 1/32, 1/16, 1/8, 1/4, 1/2, 1, 2, or 4 beats. The first
  shifted sizes are intentionally extremely short.
- CUE output follows Mixxx's `cue_indicator`. Its flash pattern therefore
  follows the user's Mixxx cue mode rather than a controller-side animation.
- SLICER is a historical compatibility page, not a native Mixxx slicer. Pads
  1-4 preview sampler slots, pad 5 invokes spinback, pad 6 invokes brake, and
  pads 7-8 are reserved. Brake can stop the track and thereby change the normal
  CUE indication.

On a normal Mixxx quit, all mapped lights were physically observed to clear.
If the controller is unplugged, the bridge exits cleanly. Reconnect the Twitch,
restart the bridge, and then restart Mixxx; Mixxx 2.5.6 does not hot-discover a
recreated virtual Core MIDI endpoint while it is already running.

Physical panel labels and locations are indexed in
`../../reference/TWITCH_PANEL_CONTROLS.md`.
