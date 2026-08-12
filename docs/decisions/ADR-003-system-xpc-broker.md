# ADR-003: Research a minimal system-domain XPC audio broker

- Status: proposed for bounded, USB-independent feasibility testing
- Date: 2026-08-12
- Branch: `experiment/audio-hal-bridge`
- Supersedes: only the GUI-LaunchAgent topology rejected by ADR-002

## Context

The Phase 2 version 0.3.0 test established that an AudioServerPlugIn hosted by
the Apple-signed Core Audio driver service performs Mach-service lookup in the
system bootstrap domain. A service registered only in the logged-in user's GUI
domain was invisible even though macOS honored `AudioServerPlugIn_MachServices`
and extended the host sandbox. The helper had zero launches and Core Audio's
frames were safely discarded.

The project will not solve that failure by making audio memory world writable,
running the complete USB/audio engine as root, disabling SIP, or weakening
macOS security. The entitlement-dependent AudioDriverKit/USBDriverKit design
remains the preferred distribution architecture if a community contributor
obtains Apple's approval.

This ADR evaluates whether a much smaller system-domain component can bridge
the namespace boundary while all USB and audio scheduling remain in the
logged-in user's process.

## Current platform evidence

The following are current SDK or operating-system facts, not project guesses:

- `AudioServerPlugIn.h` in the macOS 26.5 SDK permits an AudioServerPlugIn to
  access Mach services named in `AudioServerPlugIn_MachServices`.
- `xpc_connection_create_mach_service()` requires the name to exist in a Mach
  bootstrap namespace accessible to the caller.
- `launchctl(1)` distinguishes system, user, and GUI/login domains. User and GUI
  names are flat with each other; it does not make them visible to the system
  domain.
- A job in `/Library/LaunchDaemons` advertises services in the system domain.
- `launchd.plist(5)` permits a system-domain job to specify `UserName` and
  `GroupName`; a system service does not inherently have to execute as root.
- The tested Mac has the built-in `nobody` account (UID/GID 4294967294) but no
  `_nobody` account.
- XPC can box a caller-owned `MAP_SHARED` mapping with `xpc_shmem_create()` and
  map it in a recipient with `xpc_shmem_map()`.
- The public Security framework exposes `SecCodeCreateWithXPCMessage()`, which
  derives a live `SecCode` reference from the audit token attached by XPC to a
  received dictionary message. The broker need not trust a caller-supplied PID.
- XPC endpoints and shared-memory objects are message values. Code may create
  connections from anonymous endpoints, although endpoint relay is not required
  by the proposed design.
- macOS 12 and later can enforce a code-signing requirement directly on an XPC
  listener or peer connection. macOS 14.4 and later additionally exposes
  explicit Apple-platform and same-team peer identity requirements.
- The public macOS 14+ `xpc_listener_t` API binds a listener to a specific
  Mach-service name. Listener-level code-signing requirements arrive in 14.4,
  so the broker proof can give its HAL and helper names distinct policies in one
  process rather than trusting a self-declared role.
- The current Core Audio driver host is Apple platform code with signing
  identifier `com.apple.audio.Core-Audio-Driver-Service.helper` and designated
  requirement `identifier ... and anchor apple`.
- Apple's `SMAppService` is the current API for app-managed LaunchDaemons, but
  its SDK contract requires an app containing a LaunchDaemon to be notarized.
  This is not available to a no-cost, ad-hoc source build.
- The same SDK contract says legacy LaunchDaemons installed under
  `/Library/LaunchDaemons` continue to be bootstrapped without separate System
  Settings approval because writing to `/Library` is already protected.

Primary references:

- [Apple QA1811: AudioServerPlugIn Mach services](https://developer.apple.com/library/archive/qa/qa1811/)
- [Apple XPC documentation](https://developer.apple.com/documentation/xpc)
- [Apple TN3127: code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
- [Apple SMAppService documentation](https://developer.apple.com/documentation/servicemanagement/smappservice)
- local macOS 26.5 SDK headers and the `launchctl(1)` / `launchd.plist(5)` man
  pages installed with macOS 26.5.2 and Xcode 26.6

## Proposed architecture

```text
Mixxx / Core Audio
        |
        v
AudioServerPlugIn in Apple Core Audio driver host
        |
        | system Mach service: ...broker.hal
        v
minimal system-domain XPC broker (runs as nobody)
        |
        | one anonymous, bounded shared-audio ring
        ^
        | system Mach service: ...broker.helper
        |
logged-in-user Twitch audio helper
        |
        v
IOUSBHost -> Twitch interface 0 (future phase only)
```

The broker is a rendezvous and memory-capability service, not an audio or USB
daemon. Both clients connect outward to it. It allocates one anonymous mapping
per session and sends references to the two authenticated peers. Audio samples
then move directly through the mapped ring; they do not pass through XPC
messages or broker callbacks.

Two Mach service names are required so each listener can enforce a distinct
identity policy before accepting messages:

- `com.twitchmodern.NovationTwitchModernAudioExperimental.broker.hal`
- `com.twitchmodern.NovationTwitchModernAudioExperimental.broker.helper`

Only the `.hal` name belongs in `AudioServerPlugIn_MachServices`.
The broker uses one named `xpc_listener_t` per service and targets macOS 14.4 or
later. Serving both names from one launchd job remains a required B1/B2 test,
not an established installed result.

## Component responsibilities

### AudioServerPlugIn

- Publish four output channels at 44.1 and 48 kHz.
- Connect only to the broker's `.hal` endpoint outside the real-time callback.
- Validate the ring magic, ABI, size, channel count and capacity.
- Write bounded Float32 callbacks with no allocation, IPC, lock or wait.
- Fail open to silence/drop accounting when the broker or helper is unavailable.
- Never access USB.

### System broker

- Run on demand in the system domain as `nobody`, not root.
- Expose only the two declared Mach services.
- Authenticate and assign exactly one HAL producer and one helper consumer.
- Allocate, initialize and retain the anonymous shared mapping.
- Send the same mapping capability to the paired clients.
- Track protocol version, session generation, connection state and bounded
  counters, but never inspect or transform audio samples.
- Invalidate the complete session if either peer exits, rejects the protocol or
  becomes stale. Never replay a previous session's buffered audio.
- Perform no file writes, network access, USB access, device discovery, process
  launching or persistent storage.

### User helper

- Be launched manually in the first source-build experiment. A future signed
  app may manage it, but a Login Item or LaunchAgent is not needed to test the
  broker.
- Connect outward to `.broker.helper` and map the authenticated session ring.
- Initially consume and discard deterministic samples only.
- In a later separately authorized phase, own Twitch interface 0 through the
  already proven IOUSBHost playback transport.
- Never require root.

## Security model

### Broker execution identity

The root-owned LaunchDaemon plist specifies `UserName=nobody` and
`GroupName=nobody`. Administrator authorization installs immutable executable,
plist and configuration payloads, but launchd drops the running service to the
built-in unprivileged account. The broker must not depend on a home directory or
own any persistent file.

Running as `nobody` materially limits the effect of a broker bug, but it is not
a sandbox. The implementation must remain tiny and avoid unnecessary framework
or filesystem access.

### HAL peer

The `.hal` listener requires Apple platform code with signing identifier
`com.apple.audio.Core-Audio-Driver-Service.helper`, plus the measured
`_coreaudiod` effective UID. This authenticates the host executable, not the
specific third-party plug-in loaded inside it.

The residual risk is that another AudioServerPlugIn could declare the same Mach
service and run inside an identically signed Apple host. Installing a system HAL
plug-in already requires administrator authority, but user-domain HAL loading
behavior on macOS 26 must be confirmed before this is accepted as a complete
authorization boundary. Until then, the broker experiment carries no physical
USB output.

### Helper peer

Developer ID or Apple Development signing would permit a stable team/signing
requirement. A public source build cannot assume either. Apple explicitly notes
that ad-hoc code does not provide a stable, signer-backed identity.

For a local ad-hoc experiment, the strongest available composite check is:

1. exact installed helper CDHash generated during the reviewed build/install;
2. running-code validation using `SecCodeCreateWithXPCMessage()` and
   `SecCodeCheckValidity()`, not a caller-supplied PID;
3. exact canonical executable path;
4. root ownership and no group/other write permission on the executable and
   every installed parent directory;
5. expected non-root effective UID and current GUI audit session;
6. one live helper per broker session.

A copied exact binary can share the same CDHash, which is why path and ownership
checks are also required. The live-code lookup has a public API; whether the
whole composite check remains race-free and reliable for an ad-hoc
hardened-runtime binary is an explicit feasibility test. Failure means the
source-build broker stops; it does not fall back to identity-by-name or UID
alone.

### Shared memory

There is no POSIX name and no filesystem permission. Only authenticated peers
receive the XPC shared-memory capability. Both trusted endpoints necessarily
map the ring read/write because producer and consumer counters share the ABI.
Unrelated local processes receive no mapping handle.

The broker retains the owner mapping for the session but must never read or
write sample storage after initialization. Protocol metadata and atomic indices
remain validated and bounded exactly as in the existing ABI-v1 implementation.

## Installation and distribution models

### Bounded source-build experiment

Potential payloads, subject to a separate installation-contract review:

```text
/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver
/Library/Application Support/Novation Twitch Modern Audio/TwitchAudioBroker
/Library/Application Support/Novation Twitch Modern Audio/TwitchAudioUserHelper
/Library/LaunchDaemons/com.twitchmodern....broker.plist
```

All are copied by an exact-target administrator script, owned by `root:wheel`
and not group/other writable. The broker process itself runs as `nobody`; the
helper is invoked without `sudo` by the logged-in user. Uninstall must first
boot out the exact system service, validate every identity/path, remove only
project-owned payloads and require a normal reboot for Core Audio.

This legacy protected-filesystem route is source-installable but is not the
preferred polished distribution experience.

### Polished distribution

A containing application should use `SMAppService` to register and remove its
embedded LaunchDaemon. Apple requires such an application to be notarized, so a
paid Developer ID custodian remains necessary even though DriverKit
entitlements are not. User approval in System Settings is expected.

## Multi-user and lifecycle constraints

The Twitch is one physical device while the HAL service is system-wide. Fast
user switching can produce multiple GUI sessions and candidate helpers. The
first prototype must refuse ambiguous sessions rather than select one silently.
Before USB output, the broker must bind the helper to the current active console
session and react safely to logout or console-user changes.

Required lifecycle behavior:

- helper-before-HAL and HAL-before-helper pairing;
- generation token per mapping;
- stale-frame discard on every new pairing;
- single producer and consumer enforcement;
- protocol mismatch refusal;
- bounded heartbeats and disconnect detection;
- session invalidation on broker/helper/HAL exit;
- no automatic retry loop that masks an architecture failure;
- later StartIO creates a fresh session rather than reusing orphaned memory.

## Reuse and licensing

- Existing MIT-licensed ABI-v1 ring logic and libASPL integration are directly
  reusable within this repository.
- Existing local XPC shared-memory code proves same-domain mechanics and is a
  useful starting point, but its one-listener GUI service is not reused as an
  installed topology.
- Apple's SDK headers and samples are behavioral/API authority; sample code is
  reused only under its supplied license.
- The MIT DJM-T1 project is precedent that system-domain installation can bridge
  a HAL plug-in to a USB process. Its root execution, boot-time persistence and
  world-writable named shared memory are explicitly not copied.
- No Linux GPL implementation code or proprietary Novation binary code is
  copied.

## Decision

The system broker is **plausible enough for a bounded USB-independent proof**,
but is not yet accepted for physical audio. The design materially improves on a
root USB daemon: the only system-domain process is unprivileged and handles
capabilities/session state only.

Implementation is gated by the tests in `audio/BROKER_RESEARCH_STATUS.md` and a
new installation contract. No broker, daemon or HAL payload is installed as
part of this research decision.

## Stop conditions

Stop this path if any of the following is measured:

- a `nobody` system service cannot accept both required client domains;
- secure helper authentication requires Developer ID signing or private API;
- a different AudioServerPlugIn can impersonate the intended HAL role without
  administrator-level modification;
- the broker must run as root during normal operation;
- audio memory must be named or writable by unrelated processes;
- reliable install, bootout, uninstall or reboot cleanup cannot be provided;
- login, logout, fast-user switching or controller coexistence cannot fail safe.
