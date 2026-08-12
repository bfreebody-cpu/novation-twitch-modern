# Research and implementation history

This is the concise public timeline. Detailed contemporaneous records are under
`docs/history/`. Raw captures are intentionally not published.

| Milestone | Result |
|---|---|
| M0 | Canonical Linux quirk dependencies and Mixxx 2.3.6 mapping pinned and hash-verified |
| M0.5 | IOUSBHost descriptor probe measured both interfaces, alternates, and four endpoints |
| M1a | Linux-derived interface-0 `0 -> 1 -> 0` activation enabled raw controller input on `0x84` |
| M1b | Physical inputs characterized; fragmentation, sustained use, and disconnect handling passed |
| M2 | Core MIDI virtual source verified 408/408 events in exact order with an independent consumer |
| M3 | Current Mixxx 2.5.6 mapping implemented and physically verified |
| M4/controller v1 | Bidirectional MIDI, 101 state connections, both-deck LEDs, quit/restart/disconnect behavior verified |
| A1 | Four-channel packed-24 playback and simultaneous `0x82` input proven at 48 kHz |
| A1.5 | Sustained 30-minute 48 kHz and 10-minute 44.1 kHz scheduling passed; physical I/O channel map established |
| A3 | Conversion/ring core and unsigned AudioDriverKit scaffold compile; activation and transport implementation incomplete |
| HAL Phase 1 | Experimental AudioServerPlugIn loaded under SIP and published a four-output 44.1/48 kHz device |
| HAL Phase 2 | Anonymous XPC shared memory passed local tests, but the installed Core Audio host could not see a GUI-domain LaunchAgent; topology rejected and cleanly removed |
| Broker B0 | A minimal non-root system-domain XPC rendezvous design was researched; synthetic B1 is ready, but installation and physical USB remain gated |

## Measured USB topology

- Interface 0 alt 0: no endpoints
- Interface 0 alt 1: isochronous OUT `0x01`, max 588 bytes; isochronous IN
  `0x82`, max 294 bytes
- Interface 1 alt 0: interrupt OUT `0x03`, max 8 bytes; interrupt IN `0x84`,
  max 8 bytes

## Measured audio topology

- Playback: four-channel signed packed-24 little-endian
- Rates: 44.1 and 48 kHz
- Channels 1/2: MASTER left/right
- Channels 3/4: CUE left/right
- BOOTH switched to MASTER follows channels 1/2
- Capture channel 1: AUX left; channel 2: AUX right
- Mono MIC appears on both capture channels

At 48 kHz, OUT uses 48 audio frames / 576 bytes per USB frame. At 44.1 kHz,
OUT uses the exact 900 × 44-frame and 100 × 45-frame cadence per second. The
bounded userspace scheduler that passed sustained tests maintained a 64-frame
horizon as 8 batches of 8 frames; that is a USB scheduling bound, not a declared
Core Audio latency.

## Evidence policy

Findings distinguish supplied documentation, canonical upstream source,
physical observation, and hypotheses. Machine-readable control inventories are
public. Large raw USB/audio captures and machine registry snapshots remain in
the private forensic archive; their omission does not change the stated pass
counts or integrity/provenance anchors.
