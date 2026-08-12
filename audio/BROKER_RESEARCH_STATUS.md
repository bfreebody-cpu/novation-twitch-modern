# System XPC broker research status

- Date: 2026-08-12
- Scope: architecture and evidence only
- Implementation started: **NO**
- System payload installed: **NO**
- USB accessed: **NO**
- Physical audio produced: **NO**

## Question

Can a minimal system-domain XPC service securely rendezvous the isolated Core
Audio driver host with a logged-in-user IOUSBHost helper, without running USB or
audio logic as root and without world-writable shared memory?

## Research result

**Plausible, with one material identity gap that must be tested before physical
audio work.**

The prior Phase 2 failure was namespace placement, not an XPC or shared-memory
failure. A system-domain service is placed in the namespace the measured Core
Audio host queried; an installed visibility test is still required. A system
LaunchDaemon may use `UserName`/`GroupName` to run as the built-in `nobody`
account after administrator-controlled registration. Anonymous XPC shared
memory can then be distributed to two authenticated peers.

The recommended broker has two service endpoints, one for HAL and one for the
user helper, so each listener can enforce a different peer policy. It does no
USB work and is not in the real-time audio data path after handing out the ring.

## Established evidence

### Supplied/measured repository evidence

- Core Audio successfully loaded the ad-hoc AudioServerPlugIn under SIP.
- The plug-in published four outputs and 44.1/48 kHz.
- The HAL received 469 callbacks / 240,128 frames in the bounded installed
  Phase 2 run.
- macOS honored `AudioServerPlugIn_MachServices` but looked up the name in the
  system domain; the GUI/501 service was invisible.
- ABI-v1 ring tests, same-UID XPC handoff, 44.1/48 kHz synthetic runs,
  access-control rejection, sanitizers and a 30-minute POSIX transport soak
  passed.
- The installed experiment was completely and cleanly removed.
- IOUSBHost playback through endpoint `0x01` and the four physical output
  channels were proven independently in A1/A1.5.

### Current canonical Apple source/documentation

- The macOS 26.5 SDK exposes XPC shared-memory and endpoint values.
- XPC Mach names must be accessible in the caller's bootstrap namespace.
- System launchd jobs may declare a non-root `UserName` and `GroupName`.
- XPC supports listener-enforced signing requirements on macOS 12+ and
  Apple-platform/same-team requirements on macOS 14.4+.
- The public macOS 14+ `xpc_listener_t` API creates a listener for a specific
  Mach-service name, allowing one process to keep HAL and helper policies on
  separate named listeners; multi-service launchd behavior still needs testing.
- `SecCodeCreateWithXPCMessage()` publicly derives the sender's live code object
  from an XPC message's audit token, avoiding PID-based identity lookup.
- `SMAppService` is the current app-managed daemon API, but an app containing a
  LaunchDaemon must be notarized.
- Protected-filesystem legacy LaunchDaemons remain recognized by macOS for
  locally administered installations.

### Open-source precedent

The pinned MIT DJM-T1 implementation installs a system LaunchDaemon and HAL
plug-in. It proves architectural demand for a system-visible helper, but it runs
the device bridge as root, starts it at boot and uses named shared memory. Those
choices are not accepted for the Twitch broker.

## Facts versus hypotheses

| Claim | Status |
|---|---|
| GUI LaunchAgent is invisible to the installed Core Audio host | measured fact |
| System Mach service is in the namespace the host queried | strongly supported by launchd evidence; install test still required |
| System LaunchDaemon can execute as `nobody` | documented fact |
| One XPC shared-memory object can be mapped by two separately connected clients | supported API composition; deterministic test required |
| Broker can strongly authenticate the Apple Core Audio host | supported by current platform-identity API and measured signing identifier; live test required |
| Broker can securely authenticate an ad-hoc user helper | public live-code lookup exists; the composite CDHash, canonical-path and ownership policy still requires deterministic tests |
| Broker can determine and bind the active console session without private API | hypothesis requiring current public-API review/test |
| Broker can exit/restart without stale audio or leaked capability state | hypothesis requiring lifecycle tests |
| Broker has no effect on Bluetooth/login timing when idle | hypothesis requiring clean install/reboot comparison |
| User helper can later retain IOUSBHost access while broker runs as `nobody` | likely because broker never owns USB; physical test deferred |

## Proposed milestones

### B0 — evidence and architecture

- [x] Explain the Phase 2 namespace failure from Apple documentation and logs.
- [x] Identify system-domain non-root execution support.
- [x] Identify XPC shared-memory and peer-requirement APIs.
- [x] Define two endpoints, roles, threat model and installation choices.
- [x] Separate source-build installation from notarized distribution.
- [x] Record open-source precedent and rejected behaviors.

**B0 COMPLETE: YES.**

### B1 — process-local broker model; no installation

Build only a synthetic broker and two synthetic clients. Do not load Core Audio
or access USB.

Required tests:

- broker allocates one anonymous mapping and gives it to both clients;
- deterministic producer-to-consumer integrity at 44.1 and 48 kHz;
- helper-before-HAL and HAL-before-helper;
- wrong role, wrong protocol and duplicate peer rejection;
- code-signing requirement rejection;
- broker/client exit at every ordering boundary;
- stale session cannot be reacquired;
- ASan/UBSan/TSan and bounded CPU/memory checks.

This test uses an ordinary user launchd domain only to validate broker logic. It
does not claim system-domain feasibility.

### B2 — system-domain broker visibility; no HAL and no USB

After separate review of a new installation contract:

- install only the exact root-owned broker executable and LaunchDaemon plist;
- configure launchd to run it as `nobody`;
- connect two synthetic logged-in-user clients;
- confirm peer credentials, mapping handoff, no persistent files and on-demand
  exit/restart;
- verify bootout, removal and reboot cleanup.

This is the first milestone requiring administrator involvement.

### B3 — installed HAL-to-user-helper proof; still no USB

Install the previously proven experimental HAL plus the broker. The helper only
discards deterministic Core Audio samples.

Required gates:

- actual Apple Core Audio host passes only the HAL listener policy;
- unrelated and role-swapped clients are rejected;
- user helper passes exact ad-hoc identity/path/ownership policy;
- 44.1 and 48 kHz delivery is exact;
- helper/HAL/broker start ordering and restart are safe;
- 30-minute Core Audio soak has bounded fill, CPU and memory;
- logout/console-user ambiguity fails closed;
- complete uninstall/reboot returns the clean baseline.

### B4 — playback adapter

Only after B3 review may the user helper reuse the proven IOUSBHost interface-0
playback adapter. Begin again with physical levels down, speakers off, bounded
silence and then a low-level deterministic tone. Controller code remains frozen
unless a measured interface-ownership conflict requires a narrow change.

## Installation decision

No installation is authorized by this research. Before B2, create a replacement
contract defining exact paths, owners, modes, service identity, registration,
bootout, rollback and normal-reboot behavior. It must explicitly verify that the
running broker is `nobody`, not root.

## Remaining gaps

1. Confirm race-free `SecCodeCreateWithXPCMessage()` validity, CDHash,
   canonical-path and ownership validation for the ad-hoc helper.
2. Confirm two named `xpc_listener_t` instances can serve one launchd job and
   retain distinct peer policies.
3. Confirm whether any user-installable HAL plug-in can obtain the same Apple
   host identity and declare the broker's HAL service.
4. Define public active-console-user/session selection and fast-user-switching
   refusal.
5. Determine whether legacy local LaunchDaemon installation produces additional
   macOS background-item approval/notification behavior.
6. Define upgrade behavior when the helper CDHash changes.

The B1/B2 broker proof targets macOS 14.4 or later so it can use the named
listener and listener-level peer-requirement APIs. The existing controller
software's deployment target is unchanged.

## Readiness

- **B1 READY: YES** — process-local, synthetic and reversible.
- **B2 READY: NO** — installation contract and helper identity proof are still
  required.
- **B3 READY: NO** — depends on B1/B2.
- **PHYSICAL USB/AUDIO READY: NO** — depends on completed B3 review.
