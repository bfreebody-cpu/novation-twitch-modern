# Canonical Linux USB-audio evidence manifest

- Upstream: `https://github.com/torvalds/linux`
- Commit: `db2ddb87143519e20a95aa36c60b36107b736a58`
- Upstream subtree: `sound/usb/`
- Verification date: 2026-08-10
- Public-tree policy: provenance only; GPL kernel source snapshots are not
  vendored here

Every file in the private research set was compared byte-for-byte with the
corresponding raw Git blob at this exact commit. No Linux source was copied into
the macOS implementation.

| Upstream path | Git blob SHA-1 | Role | Twitch-specific? |
|---|---|---|---|
| `sound/usb/card.c` | `6a3b576fb06792ce22a3b7bc06ddc7a20693900d` | probe order and boot-quirk dispatch | Context |
| `sound/usb/midi.c` | `f8996416c3be15cd4301344a531b72d823f4429d` | raw MIDI endpoint discovery/read/write | Selected generic behavior |
| `sound/usb/quirks-table.h` | `71444c2898b4b281eba924ec3e96020757c2a560` | `1235:0018` fixed playback/raw MIDI entry | Yes |
| `sound/usb/quirks.c` | `90ca39dbed18bee89873630df86814266e93ab43` | Novation boot quirk and fixed endpoint creation | Yes plus generic context |
| `sound/usb/clock.c` | `2e0c18e352812359c3a90cd36d0fe9cf7672bf32` | sample-rate control | Context |
| `sound/usb/clock.h` | `ed9fc2dc051031aa28b5b5fd04d2723ab488d2a5` | clock declarations | Context |
| `sound/usb/endpoint.c` | `a1d449f2a34235b53f2b095ea8ef3d31b66e20e6` | isochronous endpoint cadence/scheduling | Context |
| `sound/usb/endpoint.h` | `ba70f52f68602eb08cc05c3f67579271ef7a6301` | endpoint declarations | Context |
| `sound/usb/helper.c` | `497d2b27fb59eff6b0f547c15b752c83c7620b74` | USB control helpers | Dependency |
| `sound/usb/helper.h` | `0372e050b3dc47ed10e43b7511dad4c57deb662e` | helper declarations | Dependency |
| `sound/usb/midi.h` | `2100f1486b03dd2a491601c5802fd9036cb8b952` | raw MIDI declarations | Dependency |
| `sound/usb/midi2.c` | `83980fb83ac84b86e4dcae8d1c634ed4ff1d12ae` | current MIDI context | Context |
| `sound/usb/midi2.h` | `94a65fcbd58ba758932648ad92ff8f622e3df9b8` | MIDI 2 declarations | Context |
| `sound/usb/pcm.c` | `682b6c1fe76bac0da615592474c9b2d7f5c6294f` | fixed playback stream/PCM behavior | Context |
| `sound/usb/pcm.h` | `c096021adb2b113aecde6e30742cd325fc0db3b9` | PCM declarations | Dependency |
| `sound/usb/quirks.h` | `f24d6a5a197a641dac36eb3c6eca5dbf5076b495` | quirk declarations | Dependency |
| `sound/usb/stream.c` | `b2c5c8198281ad1e4d81a10b6c3cbceb77c87902` | audio format/stream creation | Context |
| `sound/usb/stream.h` | `61b9a133da018a08d36dea28247266c8cc3113a9` | stream declarations | Dependency |
| `sound/usb/usbaudio.h` | `e26f9092417ed06d4c28a7b5f314d742d5895fe8` | quirk types/shared structures | Dependency |

Retrieve any file directly from:

```text
https://raw.githubusercontent.com/torvalds/linux/db2ddb87143519e20a95aa36c60b36107b736a58/<upstream-path>
```
