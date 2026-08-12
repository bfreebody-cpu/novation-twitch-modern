# USB-independent HAL and shared-memory probe

This experimental plug-in publishes a virtual four-channel output device named
`Novation Twitch Modern Audio - Experimental`. It accepts 32-bit interleaved
floating-point Core Audio samples at 44.1 or 48 kHz.

In Phase 2, its mixed-output callback writes those frames to the versioned
single-producer/single-consumer ring documented in `../shared/README.md`. The
on-demand `TwitchAudioXPCService` process consumes and discards them. XPC is used
only to acquire the anonymous mapping outside the real-time callback. If the
ring is full or unavailable, the callback drops frames and never waits.

The plug-in and helper contain no USB code, never discover or open the Twitch,
and produce no physical audio output.

Build from the repository root:

```sh
scripts/audio/build-hal-probe.sh
```

The build downloads libASPL from its official GitHub repository at the exact
commit recorded in `audio/DEPENDENCIES.md`. The resulting bundle is ad-hoc signed
for local feasibility testing.

Run a USB-independent two-process test after building:

```sh
scripts/audio/run-shared-audio-test.sh 10 48000
scripts/audio/run-shared-audio-rate-change-test.sh
scripts/audio/run-shared-audio-restart-test.sh
scripts/audio/run-xpc-shared-audio-test.sh 10 48000
scripts/audio/run-xpc-shared-audio-test.sh 10 44100
scripts/audio/run-xpc-access-control-test.sh
```

The first command uses a deterministic synthetic producer rather than Core
Audio. Captures are written under the ignored `captures/audio/` directory.

After a separately reviewed installation and required reboot, the installed
HAL path can be exercised without USB access using:

```sh
scripts/audio/run-live-hal-phase2-test.sh 5 48000
scripts/audio/run-live-hal-restart-test.sh
```

Both scripts refuse to run when the exact experimental bundle is absent.

Installation and removal are separate administrator-authorized operations. Read
`audio/INSTALLATION_CONTRACT.md` before running either script.

A normal reboot is required after installation and after removal. The scripts do
not attempt to restart SIP-protected Core Audio services.

## Measured Phase 1 result

On arm64 macOS 26.5.2, the ad-hoc-signed bundle loaded after a normal reboot
with SIP enabled. Core Audio published four output channels and both discrete
sample rates, and StartIO/StopIO passed at 44.1 and 48 kHz. Mixxx 2.5.6 also
discovered the experimental device:

![Mixxx Sound Hardware showing Novation Twitch Modern Audio - Experimental](../../docs/images/audio-hal-mixxx-discovery.png)
