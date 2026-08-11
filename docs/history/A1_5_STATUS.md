# A1.5 sustained audio clock and scheduler status

Date: 2026-08-10/11 (America/Toronto)

## Scope and decision

A1.5 sustained transport validation is complete at 48 kHz and 44.1 kHz.
Controlled microphone and AUX injection proves that `0x82` carries capture
audio, and controlled output tests identify the MASTER and CUE stereo playback
pairs at the headphones, BOOTH and direct balanced MASTER jacks.

- Core Audio device created: **no**
- DriverKit or AudioDriverKit used: **no**
- Vendor-specific requests issued: **no**
- Controller implementation modified: **no**
- Audio interface used: interface 0 only
- OUT traffic: generated packed-24 silence and bounded -48 dBFS tones only
- IN traffic: endpoint `0x82` observation, including controlled analog input
- Interface 0 restored to alternate 0 after completed runs: **yes**

**A1.5 COMPLETE: YES.**

**A2 READY: YES — `0x82` is proven capture audio, AUX channel identity is
measured, and mono microphone capture is measured on both channels. Exact sample
scaling and production full-duplex policy remain A2 work.**

**A3 PLAYBACK-ONLY READY: YES — sustained scheduling and the 1/2 MASTER,
3/4 CUE playback map are established. The device-session lifecycle anomaly
remains a hardening item, not a protocol blocker.**

## Canonical evidence captures

| Capture | Purpose | Result |
|---|---|---|
| `captures/20260810T235549.116Z-twitch-a1-5-48000hz/` | 10-second 48 kHz smoke | Passed; zero errors; 16-frame scheduler lead 9-25 frames |
| `captures/20260810T235741.551Z-twitch-a1-5-48000hz/` | First sustained attempt | Failed closed after 140,556 frames when the 16-frame horizon became stale |
| `captures/20260811T001156.616Z-twitch-a1-5-48000hz/` | Three-minute 64-frame proof | Passed all 180,000 frames |
| `captures/20260811T001721.360Z-twitch-a1-5-48000hz/` | 30-minute 48 kHz run | All transport passed; post-controller prompt deliberately not confirmed because its independent timer had elapsed |
| `captures/20260811T004959.072Z-twitch-a1-5-44100hz/` | Ten-minute 44.1 kHz run | Passed all 600,000 frames and post-controller check |
| `captures/20260811T153139.328Z-twitch-a1-5-48000hz/` | MIC speech then quiet, single session | Capture signal follows microphone; mono source appears on both channels |
| `captures/20260811T153538.410Z-twitch-a1-5-48000hz/` | AUX quiet then stereo program | Capture signal follows AUX program |
| `captures/20260811T153850.582Z-twitch-a1-5-48000hz/` | AUX right-only then left-only | Channel 1 = AUX LEFT; channel 2 = AUX RIGHT |
| `captures/20260811T152151.796Z-twitch-a1-5-48000hz/` through `20260811T152647.131Z-...` | Repeated short-session lifecycle investigation | IN degraded from two normal packets to all successful zero-length transactions; OUT stayed healthy |
| `captures/20260811T154547.848Z-twitch-a1-audio/` | Headphone MASTER isolation | Channels 1/2 = left/right; 3/4 silent; see operator correction |
| `captures/20260811T154929.448Z-twitch-a1-audio/` | Headphone CUE isolation | Channels 1/2 silent; 3/4 = left/right |
| `captures/20260811T155724.910Z-twitch-a1-audio/` | BOOTH with source switch MASTER | Channels 1/2 = left/right; 3/4 silent |
| `captures/20260811T160539.610Z-twitch-a1-audio/` | Direct balanced MASTER L/R to KRK Rokit 5 | Channels 1/2 = left/right; 3/4 silent |

The 30-minute capture's `summary.json` has `completed: false` only because the
operator-confirmation prompt was intentionally rejected after the bounded M4
bridge had stopped. Its OUT and IN schedules, evidence analysis and alternate-0
restoration all completed. This distinction must not be collapsed into a USB
transport failure.

## Scheduler findings

### Measured failure

The original sustained policy queued four batches of four USB frames with an
initial 16-frame lead. It ran for 140.556 seconds, then refused to submit frame
27,298,993 because the observed controller frame was already 27,298,994. The
largest preceding completion-callback gap was 18.108 ms, longer than the queue
horizon. The harness stopped before submitting the stale frame. It did not retry
or hide the defect, and no `kIOReturnIsoTooOld` transaction was submitted.

### Validated policy

The evidence-driven validation policy is:

- initial lead: 64 USB frames;
- batch size: 8 USB frames;
- maximum active batches: 8;
- steady queue horizon: approximately 64-65 frames;
- refill: completion-driven and incremental;
- stale-frame behavior: fail closed before submission;
- retries after stale or `IsoTooOld`: none.

This 64 ms horizon is a robustness setting for the userspace validation harness,
not a proposed Core Audio latency. During the successful 30-minute run the
minimum recorded lead was 28 frames. The maximum distinct OUT completion-callback
gap was 36.911 ms; the largest gap between recorded submission batches was
65.406 ms, with queued work preserving continuity. At 44.1 kHz the corresponding
maxima were 30.945 ms and 66.379 ms, and minimum lead was 34 frames.

No successful sustained run produced `kIOReturnIsoTooOld`, a late submission, a
short OUT transaction, underrun/overrun indication, non-monotonic record, or USB
error.

The older bounded A1 routing path still used an 8-frame lead with only three
four-frame batches. Capture `20260811T154326.287Z-twitch-a1-audio` reproduced an
actual `kIOReturnIsoTooOld` at frame 584 and shut down safely. Applying only the
A1.5-proven 64-frame lead and eight-by-eight bounded queue policy removed the
failure. Every subsequent 2,000-frame simultaneous silence gate and every
one-second tone/separator segment completed cleanly; no stale-frame retry was
added.

## 48 kHz sustained result

Rate control was physically verified:

- `SET_CUR` bytes: `80 bb 00`;
- `GET_CUR` bytes: `80 bb 00`;
- interface: 0 alternate 1 during transport;
- duration: 1,800 seconds / 1,800,000 USB frames.

OUT distribution:

- 1,800,000 packets of 576 bytes;
- 86,400,000 four-channel audio frames;
- 1,036,800,000 payload bytes;
- zero short packets and zero errors.

IN distribution:

- 1,799,995 packets of 288 bytes;
- 5 packets of 294 bytes;
- 86,400,005 candidate two-channel packed-24 frames;
- 518,400,030 payload bytes;
- zero errors.

The cumulative IN-minus-OUT difference was +5 audio frames in the first
one-second aggregate and remained exactly +5 through all 1,800 aggregates. This
is a fixed startup phase difference, not accumulated drift.

The OUT transaction timestamp interval measured mean 999.9906 microseconds,
standard deviation 4.747 microseconds, minimum 934.833 microseconds and maximum
1,070.292 microseconds. IN measured mean 999.9906 microseconds, standard
deviation 4.774 microseconds, minimum 928.708 microseconds and maximum 1,076.458
microseconds. These are host-observed transaction timestamps, not an end-to-end
analog latency measurement.

## 44.1 kHz sustained result

Rate control was physically verified:

- `SET_CUR` bytes: `44 ac 00`;
- `GET_CUR` bytes: `44 ac 00`;
- duration: 600 seconds / 600,000 USB frames.

OUT used the exact four-channel packed-24 phase-accumulator cadence:

- 540,000 packets of 528 bytes (44 audio frames);
- 60,000 packets of 540 bytes (45 audio frames);
- exactly 900:100 packets per second;
- 26,460,000 audio frames and 317,520,000 bytes;
- zero errors or short packets.

IN distribution was the corresponding two-channel cadence with a fixed phase
offset:

- 540,003 packets of 264 bytes (44 candidate audio frames);
- 59,997 packets of 270 bytes (45 candidate audio frames);
- 26,459,997 candidate audio frames and 158,759,982 bytes;
- zero errors.

IN-minus-OUT was -3 frames in the first one-second aggregate and stayed exactly
-3 through all 600 aggregates. It did not drift.

OUT timestamp intervals measured mean 999.9909 microseconds, standard deviation
4.764 microseconds, minimum 936.833 microseconds and maximum 1,063.917
microseconds. IN measured mean 999.9909 microseconds, standard deviation 4.816
microseconds, minimum 927.500 microseconds and maximum 1,081.708 microseconds.

## `0x82` interpretation

### Established by physical evidence

- It is not a 3/4-byte explicit-feedback transfer in these runs.
- Every successful payload length is divisible by six.
- At 48 kHz its dominant payload is 288 bytes, exactly 48 × 2 × 3.
- At 44.1 kHz it uses 264/270-byte packets in the expected 44/45-frame cadence.
- Its aggregate frame count has a small fixed startup phase offset from OUT and
  then remains drift-free for 30 minutes at 48 kHz and ten minutes at 44.1 kHz.
- Known microphone speech produces a large capture signal which falls to the
  noise floor when the microphone is made quiet/off in the same uninterrupted
  session.
- Known AUX program produces capture signal; right-only wiring produces signal
  only in candidate channel 2 and left-only wiring only in candidate channel 1.
- A mono microphone appears nearly identically in both capture channels.

The 20-second microphone capture completed 20,000 IN and OUT USB frames with no
errors. IN was 19,969 × 288, 15 × 282 and 16 × 294 bytes. Under provisional
stereo signed packed-24 decoding, speaking produced per-second AC RMS values from
roughly 38,000 to 134,000 on both channels; after the mic was quiet/off, the last
two seconds fell to approximately 397/401 and then 58/59. Whole-run channel RMS
was 68,215 and 68,716, consistent with a mono source duplicated to both channels.

The decisive 40-second AUX isolation completed 40,000 frames with 39,990 × 288
and 10 × 282-byte IN packets, no USB errors and a fixed -10-frame startup phase.
During clean right-only program, channel 1 remained around 51-313 AC RMS while
channel 2 carried roughly 4,500-7,650. During clean left-only program, channel 1
carried roughly 3,890-4,210 while channel 2 remained around 61-88. Cable-swap
transients were excluded from those ranges.

### Interpretation confidence

`0x82` is now **proven to carry capture audio** and independently supplies useful
device-clock cadence. Its lengths and signal decoding give high confidence in
stereo signed packed-24 little-endian transport, but exact numeric scaling and a
bit-accurate encoding proof remain for A2. Evidence does not yet establish
whether playback must use its cadence as an implicit clock reference.

## Controller coexistence and lifecycle

- The unchanged M4 bridge owned interface 1 while the sustained audio harness
  owned interface 0.
- PLAY/CUE input and Mixxx-driven LED output were verified before and after the
  three-minute 48 kHz test and ten-minute 44.1 kHz test.
- During the 30-minute 48 kHz run the M4 bridge coexisted for 29 minutes 46
  seconds. Its separately bounded timer started before audio and stopped 14
  seconds before audio completion. No controller failure caused the stop.
- The operator correctly declined the impossible post-run controller prompt;
  the harness recorded that fact and restored interface 0.

Operational finding: when the Twitch is unplugged, the current bridge process
exits and its Core MIDI endpoints disappear. Mixxx can retain stale endpoint
references and may need a bridge-first/Mixxx restart. A future persistent service
should keep Core MIDI endpoints alive across USB removal and reacquire the Twitch
when it returns. That controller-service improvement was not implemented during
A1.5 because the controller path is frozen.

Two troubleshooting bridge sessions ended with `device not responding` and the
Twitch USB registry session identity changed or disappeared. At least one period
included operator unplug/replug activity. The final post-44.1 registry check did
not show the Twitch enumerated. The evidence does not yet distinguish operator
disconnect, cable/hub instability, device re-enumeration after audio state
changes, or another cause. No automatic retry was attempted.

Repeated short interface-0 sessions also produced a state in which successful
`0x82` transactions became zero length while OUT remained healthy. A physical
unplug/replug restored normal full payloads. The normal alternate/rate sequence
did not recover that state. This is a measured lifecycle anomaly; its cause
(missing input initialization, device firmware state, or another session
condition) is not established. Later controlled routing sessions remained
healthy. A bridge-first then Mixxx-second restart also restored the controller
without a stale-controller dialog.

The final 27-minute coexistence bridge capture
`captures/20260811T154504.496Z-twitch-m4-bridge/` ended by Ctrl-C after all
routing tests. It recorded 139 controller-IN transfers, 46 decoded input events,
3,271 controller-OUT transfers, zero Core MIDI errors, an empty output queue,
synchronous input-pipe abort, and both interfaces idle at alternate 0 afterward.
The private capture's device session and location identifiers were unchanged.

## Output routing status

Controlled -48 dBFS one-channel tones establish:

| USB playback channel | Headphones: MASTER | Headphones: CUE | BOOTH: MASTER | Direct balanced MASTER |
|---|---|---|---|---|
| 1 | left | silent | left | left |
| 2 | right | silent | right | right |
| 3 | silent | left | silent | silent |
| 4 | silent | right | silent | silent |

Therefore channels 1/2 are the MASTER stereo pair and channels 3/4 are the CUE
stereo pair. BOOTH in CUE-switch position remains unmeasured.

The supplied user manual establishes the connector/control topology, not USB
channel mapping:

- balanced left/right 1/4-inch MASTER outputs;
- unbalanced left/right RCA BOOTH outputs;
- BOOTH MASTER/CUE switch;
- stereo headphone outputs with MASTER/CUE MIX;
- stereo RCA AUX input and mono 1/4-inch dynamic-microphone input;
- rear DIRECT MONITORING switch.

## Remaining unknowns after A1.5

1. Exact packed-sample scaling/sign-extension and analog level calibration.
2. Whether OUT must discipline scheduling from `0x82` cadence in production.
3. Cause and software recovery strategy for the zero-length-IN lifecycle state.
4. BOOTH behavior with its source switch at CUE.
5. Sleep/wake, overload and long disconnect/reconnect behavior.

## Recommended next session

Proceed to either **A2 capture/full-duplex characterization** or the separately
authorized **A3 playback-only Core Audio prototype**. Before product work, review
the zero-length-IN lifecycle anomaly and retain fail-closed transport evidence.
