# Novation Twitch Modern

Modern Apple-silicon/macOS support for the Novation Twitch DJ controller
(`USB 1235:0018`).

The controller side is a working v1: a small Swift bridge uses supported
IOUSBHost and Core MIDI APIs to expose the Twitch as bidirectional virtual MIDI,
and a current Mixxx mapping provides deck control plus 101 state-driven LED
connections. It has been physically tested with Mixxx 2.5.6 on macOS 26.

The Twitch audio interface is not yet a Core Audio device. Its USB transport has
been characterized at 44.1 and 48 kHz, and an unsigned playback-only
AudioDriverKit/USBDriverKit scaffold compiles, but implementation and activation
require an eligible Apple Developer Program team plus Apple-approved DriverKit
entitlements. This project does not ask users to disable SIP or weaken macOS
security.

## What works

- Exact-match discovery for VID `0x1235`, PID `0x0018`
- Proven interface-0 `0 -> 1 -> 0` controller activation
- Raw interrupt MIDI input on endpoint `0x84`
- Documented basic-mode LED output on endpoint `0x03`
- MIDI stream reconstruction across fragmented USB transfers
- Core MIDI 1.0 virtual source and destination named `Novation Twitch Modern`
- Current Mixxx mapping for decks A/B, mixer, browser, performance controls,
  FX, and physically verified LED feedback
- Safe Ctrl-C and physical-removal cleanup
- Deterministic parser, USB policy, mapping, audio conversion, cadence, and ring
  tests

See [controller v1 status](docs/history/CONTROLLER_V1_STATUS.md) and the
[mapping guide](mapping/novation-twitch-modern/README.md).

**New to Terminal or Mixxx?** Start with the
[beginner guide](BEGINNER_GUIDE.md). It includes safe one-time mapping
installation, daily startup, shutdown, reconnect, and troubleshooting steps.

## Quick start: controller and Mixxx

Requirements: Apple silicon Mac, macOS 15 or newer, Swift 6.2/Xcode 26 command
line tools, Mixxx 2.5.6 or compatible, and a connected Novation Twitch.

```sh
./scripts/install-mixxx-mapping.sh
./scripts/run-controller.sh
```

Copy these two canonical mapping files into Mixxx's user controller directory:

```text
mapping/novation-twitch-modern/Novation Twitch Modern.midi.xml
mapping/novation-twitch-modern/Novation-Twitch-Modern-scripts.js
```

For the sandboxed macOS Mixxx build tested here, that directory is:

```text
~/Library/Containers/org.mixxx.mixxx/Data/Library/Application Support/Mixxx/controllers
```

Start the bridge before Mixxx. In Mixxx Preferences > Controllers, enable
`Novation Twitch Modern` and select the included mapping. After a physical
disconnect, reconnect the Twitch, restart the bridge, and restart Mixxx; Mixxx
2.5.6 does not hot-discover recreated virtual MIDI endpoints while already
running.

The root `Start Twitch Modern.command` file is a Finder-friendly wrapper around
the same safe controller launcher.

## Safety and scope

The default controller bridge never opens the audio endpoints. The separate
`twitch-a1` and `twitch-a1-5` programs are engineering research harnesses that
can generate physical audio output. Do not run them casually; lower MASTER,
BOOTH, and headphone levels and power off connected speakers before any test.

The A3 Driver Extension under `A3/` is incomplete and unsigned. Compile-only
inspection is supported; do not activate it until the remaining USB scheduler,
rate-control, cancellation, analyzer, entitlement, and safety gates are closed.

## Project status

| Area | Status |
|---|---|
| Controller input | Complete and physically characterized |
| Core MIDI input publication | Complete |
| Mixxx integration | Complete for controller v1 |
| LED/output feedback | Complete v1; optional visual polish remains |
| USB audio playback transport | Proven in bounded userspace tests |
| USB capture transport | Physically mapped; not published |
| Core Audio playback device | Incomplete; unsigned scaffold only |
| Core Audio capture device | Deferred |

The detailed research timeline is in [docs/RESEARCH_HISTORY.md](docs/RESEARCH_HISTORY.md).

## Help wanted: Core Audio

The most valuable contribution is completing and validating the playback-only
AudioDriverKit/USBDriverKit path. This requires a contributor or sponsoring team
eligible to request Apple's DriverKit Audio Family and USB Transport entitlement
for `1235:0018`. Read [docs/AUDIO_CONTRIBUTORS.md](docs/AUDIO_CONTRIBUTORS.md)
before changing or activating the scaffold.

## Repository hygiene

This public repository intentionally excludes proprietary legacy Novation
drivers, Novation manuals, downloaded third-party source snapshots, and hundreds
of megabytes of raw hardware captures. Their exact hashes and upstream
provenance are retained in [reference/README.md](reference/README.md). Public
inventories and status documents preserve the measured findings without
publishing personal machine state.

## License

Original project code and the adapted mapping are licensed under
GPL-3.0-or-later. The Apple sample-derived A3 subtree retains Apple's permissive
sample notice. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
