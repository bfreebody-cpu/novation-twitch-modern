# A1 status — bounded macOS userspace playback proof

Date: 2026-08-10 (America/Toronto)

## Decision

**A1 COMPLETE: YES**

**A1.5 READY: YES — requires separate authorization.**

The canonical physical run completed 48 kHz initialization, full-capacity
endpoint-`0x82` observation, exactly two seconds of four-channel packed-24
silence, four low-level channel tones, controller coexistence and normal state
restoration. A separate final Ctrl-C smoke test also restored alternate 0.

## Scope and implementation

- Production controller checkpoint: `b2d4bce`; its M0-M4 sources were not edited.
- New executable: `twitch-a1`.
- Native API: IOUSBHost framework, current transaction-list isochronous API.
- Device match: exactly USB VID `0x1235`, PID `0x0018`.
- Claimed object: interface 0 only.
- Permitted traffic used: endpoint-class 48 kHz `SET_CUR`/`GET_CUR`, isochronous
  IN `0x82`, and isochronous OUT `0x01`.
- No controller endpoint access, vendor request, reset, configuration change,
  Core Audio object, DriverKit installation or legacy binary execution.

Descriptor, PCM generation, endpoint classification, transport, capture output
and CLI/operator gates are separated. `TwitchAudioCore` contains deterministic,
hardware-independent PCM and classification logic; `TwitchA1USB` contains the
narrow Objective-C IOUSBHost transaction boundary needed for safe pointer and
frame-list lifetimes.

## Canonical evidence

Directory: `captures/20260810T231803.901Z-twitch-a1-audio/`

Principal files:

- `a1-capture.json`: metadata, descriptors, controls, metrics, operator results,
  pre/post state and shutdown result;
- `endpoint82-full-capacity.jsonl`: 250 full-294-byte-capacity IN requests;
- `silence-out.jsonl`: all 2,000 OUT frame completions;
- `silence-concurrent-in.jsonl`: all 2,000 concurrent IN completions;
- `tone-channel-*-attempt-1.jsonl`: four one-second tones;
- `tone-separator-after-channel-*.jsonl`: three one-second silent separators;
- `tone-signal-specification.json`: fixed signal parameters;
- raw device/configuration descriptors and pre/post registry snapshots.

Final Ctrl-C evidence:

- prompt-time/no-transfer restoration:
  `captures/20260810T232347.247Z-twitch-a1-audio/`;
- active endpoint-`0x82` cancellation and restoration:
  `captures/20260810T233112.725Z-twitch-a1-audio/`.

## Initialization

| Operation | Result | Bytes | Data |
|---|---|---:|---|
| Select interface 0 alternate 1 | success, verified | — | — |
| 48 kHz `SET_CUR` (`22 01 0100 0001`) | success | 3 | `80 bb 00` |
| `GET_CUR` (`a2 81 0100 0001`) | success | 3 | `80 bb 00` |

No additional initialization was attempted.

## Endpoint `0x82`

The canonical 250-frame full-capacity observation completed without error:

- 238 packets × 288 bytes;
- 12 packets × 294 bytes;
- 72,072 bytes total;
- 240 distinct payload hashes;
- nonzero, changing content;
- 250/250 successful transfer and frame statuses.

Other bounded A1 observations also produced 282-byte packets. Dividing by six
bytes per stereo packed-24 sample frame gives exactly 47, 48 and 49 samples per
USB frame. No 3/4-byte feedback-style payload was observed.

Measured conclusion: `0x82` is an audio-data-sized input transport and is not an
explicit feedback endpoint. The historical two-input driver evidence is
consistent with stereo packed-24 capture, but a known-signal A2 experiment is
still required before claiming exact input sample semantics or jack mapping.

## Silence and timing

- OUT: 2,000/2,000 frames, each exactly 576 bytes; 1,152,000 bytes total.
- Concurrent IN: 2,000/2,000 frames, each 288 bytes in the canonical run;
  576,000 bytes total.
- USB/frame errors: 0.
- Short OUT packets: 0.
- Maximum OUT packet: 576 bytes, below the 588-byte descriptor limit.
- Scheduling leads: 8–15 frames for canonical OUT; 8–19 for concurrent IN.
- Fixed maximum outstanding depth: 12 USB transactions per endpoint.
- OUT transaction-timestamp interval: mean approximately 999.989 µs; observed
  range approximately 970.8–1,026.7 µs over 1,999 intervals.
- Concurrent-IN timestamp interval: mean approximately 999.991 µs; observed
  range approximately 965.3–1,033.4 µs.

These are USB transport timestamps, not end-to-end audio latency.

## Tone and physical observations

Signal for every channel: 440 Hz sine, signed little-endian packed 24-bit,
four-channel interleaved, `-48 dBFS`, 10 ms attack/release ramps, one second.
Digital amplitude was never increased.

All four 1,000-frame tone segments and three 1,000-frame silence separators
completed exactly 576 bytes per frame with no USB error.

Headphone observations with MASTER/CUE MIX centered and the operator reporting
MASTER and monitoring controls slightly above zero:

| USB playback channel | Physical observation |
|---:|---|
| 1 | headphone left only |
| 2 | headphone right only |
| 3 | both headphone ears |
| 4 | headphone right only |

This is an observed mix under that physical control state. It is not yet an
isolated master/booth/cue jack map.

## Controller coexistence

- The existing M4 bridge started first and retained interface-1 ownership.
- PLAY input and Mixxx LED response were confirmed before audio, after the
  two-second silence run and after all tone segments.
- A1 never opened or transferred on controller endpoints `0x03`/`0x84`.
- Pre/post device registry ID, session ID, configuration and interface states
  matched.

## Errors and robustness findings

The canonical run had no USB, control, parser or shutdown error.

Development evidence retained under `captures/` identified two real harness
issues before the canonical result:

1. A single combined seven-second tone/silence run completed 1,135 frames but
   frame 1,124 had zero bytes and `kIOReturnIsoTooOld` after scheduling lead fell
   to one frame. The harness stopped and did not continue tones. Splitting each
   one-second segment into an independently scheduled and drained bounded run
   completed all seven segments. A1.5 must harden sustained scheduling rather
   than use segmentation as a production clock policy.
2. Early Swift dispatch-source Ctrl-C handling trapped on executor isolation and
   left alternate 1 until a guarded restoration-only pass. The final design uses
   the async-signal-safe self-pipe directly for prompts and an Objective-C abort
   monitor only while USB calls are active. The final smoke test selected
   alternate 1, sent no rate/endpoint request, received Ctrl-C without crashing,
   restored alternate 0 and released ownership. A second smoke test sent Ctrl-C
   during a bounded active `0x82` frame list; the wrapper surfaced
   `kIOReturnAborted`, synchronously drained the abort, restored alternate 0 and
   released ownership.

No unexplained persistent device state remains. Current observed interface 0 is
alternate 0.

## Tests

- `swift build`: passed.
- `swift run twitch-a1-tests`: passed.
- `swift run twitch-parser-tests`: passed; frozen USB descriptor, MIDI,
  control-catalog and controller-output tests remain green.

## Remaining unknowns

- sustained 48 kHz drift and required 47/48/49-sample OUT correction policy;
- all 44.1 kHz initialization, scheduling and packet-size behavior;
- whether `0x82` is capture only or also the clock reference playback should
  follow;
- exact capture packing and physical input map;
- isolated master, booth and cue output routing;
- end-to-end latency, safety offset and AudioDriverKit timestamp mapping;
- audio unplug/reconnect, sleep/wake and long-run overload behavior.

## Exact recommended next milestone

**A1.5 — sustained dual-rate userspace transport/clock validation.**

First strengthen the rolling scheduler while retaining contiguous frame-number
scheduling, a fixed bounded queue and fail-closed behavior. Then run 30 minutes
at 48 kHz with concurrent `0x82`, quantify drift/packet correction, and perform a
separately gated 44.1 kHz run. Preserve controller coexistence and all A1 safety
exclusions. Do not create a Core Audio device during A1.5.
