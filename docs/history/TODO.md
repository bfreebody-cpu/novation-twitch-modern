# Post-v1 controller work

Controller v1 is complete. The normal and SHIFT-page state LEDs, both-deck
visual parity, normal-quit clearing, process-restart recovery, and safe physical
disconnect behavior have all been tested. The items below are optional future
features; none is required for the supported v1 controller path.

## Deferred visual features

- Choose a consistent dim inactive-color policy instead of leaving inactive
  bicolor controls off.
- Add the documented touchstrip light-guide output after defining a useful
  Mixxx state model.
- Add channel VU meters only with update-rate limiting and state coalescing.
- Design richer FX-page visualization without using basic-mode FX PARAMS notes
  28-31, which the Programmer's Reference says may not be externally controlled.
- Decide whether the Mic/Aux section needs useful Mixxx feedback.

## Deferred behavior

- Consider a purpose-built emulated slicer. The v1 SLICER page deliberately
  retains historical compatibility behavior: sampler preview, spinback, brake,
  and two reserved pads.
- Consider state coalescing only if future meters or animations exceed the
  bounded output queue. Controller-v1 traffic produced no overflow.
- Improve application-level endpoint rediscovery if a future Mixxx version
  exposes a reliable way to hot-attach recreated virtual Core MIDI endpoints.

## Audio

Twitch audio support remains separate from the stable controller code. The
unsigned AudioDriverKit prototype and the entitlement/signing blocker are
documented in `A3_STATUS.md`; do not weaken macOS security to bypass them.
