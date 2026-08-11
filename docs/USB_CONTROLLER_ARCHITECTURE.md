# USB and controller architecture

This document is the current public summary. It separates upstream evidence,
physical observation, implemented behavior, and remaining hypotheses.

## Device identity

The Novation Twitch matches exactly:

- vendor `0x1235`
- product `0x0018`
- device version `0x0100`
- full-speed USB, 12 Mb/s
- configuration 1
- vendor-class interfaces

The measured device has no serial-number string visible in the I/O Registry.
The implementation refuses unrelated VID/PID pairs.

## Measured descriptors

| Interface | Alternate | Endpoint | Type | Packet limit |
|---|---:|---|---|---:|
| 0 | 0 | none | inactive audio state | — |
| 0 | 1 | `0x01` OUT | isochronous audio data | 588 bytes |
| 0 | 1 | `0x82` IN | isochronous data | 294 bytes |
| 1 | 0 | `0x03` OUT | interrupt controller data | 8 bytes |
| 1 | 0 | `0x84` IN | interrupt controller data | 8 bytes |

Interface 1 has no alternate 1. These facts came from a read-only IOUSBHost
descriptor probe on the physical unit; no endpoint transfer was required.

## Canonical Linux behavior

The complete traced source set is pinned in
`reference/linux/MANIFEST.md` at Linux commit
`db2ddb87143519e20a95aa36c60b36107b736a58`.

Linux identifies Twitch as a composite quirk:

- interface 0: `QUIRK_AUDIO_FIXED_ENDPOINT`
- interface 1: `QUIRK_MIDI_RAW_BYTES`

`snd_usb_apply_boot_quirk()` dispatches `1235:0018` to
`snd_usb_novation_boot_quirk()`, which selects interface 0 alternate 1. The
comment says this is needed to activate the raw MIDI endpoints. The fixed audio
constructor later derives endpoint properties from alternate 1, creates the
four-channel playback stream, returns interface 0 to alternate 0, and performs
pitch/sample-rate initialization.

The fixed format is four-channel `S24_3LE`, endpoint `0x01`, at 44.1 or 48 kHz.
The raw MIDI implementation scans interface 1's current alternate for bulk or
interrupt endpoints and forwards raw ALSA MIDI bytes without USB-MIDI event
packet framing. This explains the measured interrupt pair `0x03`/`0x84`.

No Linux source is copied into this implementation; it is behavioral evidence.

## Controller protocol and activation

The Programmer's Reference defines the controller payload as ordinary MIDI 1.0
bytes. USB transfer boundaries are not message boundaries. The stream parser
therefore supports running status, fragmented messages, Note On/Off, Control
Change, realtime-byte interleaving, bounded SysEx, and incomplete-message carry.

The Linux-derived interface-0 `0 -> 1 -> 0` transition was tested physically and
is sufficient to make `0x84` readable. The controller bridge then opens only
interface 1 alt 0. It publishes decoded logical messages unchanged through a
Core MIDI 1.0 virtual source.

For output, a separate Core MIDI virtual destination accepts only documented
basic-mode messages. It packs the resulting MIDI byte stream into ordered
interrupt OUT writes of at most the descriptor-derived 8-byte limit. It rejects
advanced-mode, SysEx, system, unknown, audio, and wrong-endpoint output.

## Stable userspace architecture

```text
Twitch interface 1
    <-> IOUSBHost endpoints 0x84 / 0x03
    <-> MIDI stream parser and output policy
    <-> Core MIDI virtual source/destination
    <-> Mixxx 2.5 mapping
```

This requires no kernel extension, Driver Extension, legacy Novation driver, or
Mixxx source fork. Physical disconnect stops the bridge cleanly without retries.
Mixxx must be restarted after the bridge recreates its virtual endpoints.

## Audio facts

Userspace A1/A1.5 measurements established:

- endpoint-class 44.1/48 kHz `SET_CUR` and `GET_CUR` work;
- `0x01` carries four interleaved signed packed-24 channels;
- channels 1/2 map to MASTER left/right;
- channels 3/4 map to CUE left/right;
- a bounded 64-frame / 8-by-8 scheduling policy ran 30 minutes at 48 kHz and
  ten minutes at 44.1 kHz without stale-frame or USB errors;
- `0x82` carries stereo packed-24-like capture data: AUX left/right map to input
  channels 1/2, and mono MIC appears on both.

The public controller does not open either audio endpoint. The proposed Core
Audio implementation is documented separately in
`docs/history/AUDIO_ARCHITECTURE.md`.

## Current macOS API decisions

- IOUSBHost is sufficient for the command-line descriptor/controller and
  bounded research tools on the tested Apple-silicon Mac.
- Core MIDI's modern MIDI 1.0 event-list path is used for virtual endpoints.
- A production physical Core Audio device should use AudioDriverKit with
  USBDriverKit transport, delivered in a containing System Extension app.
- The AudioDriverKit path requires Apple-approved entitlements and normal macOS
  System Settings approval. The project will not bypass these requirements.

## Remaining hypotheses and unknowns

- Exact capture sample scaling/sign extension remains to be measured before
  publishing input channels.
- DriverKit isochronous completion timing, safe USB lead, Core Audio safety
  offset, and reported latency must be measured in the actual dext rather than
  copied from the userspace harness.
- Interface-0 ownership coexistence with the stable controller bridge must be
  tested after a properly entitled dext can activate.
- Long-run sleep/wake and distribution/notarization behavior remain future work.
