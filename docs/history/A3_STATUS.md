# A3 playback-only Core Audio prototype status

Date: 2026-08-11 (America/Toronto)

## Decision

**A3 COMPLETE: NO.**

**A4 READY: NO.**

The transport-independent playback boundary and an unsigned app+dext prototype
are implemented and compile against the installed Apple SDKs. Xcode is signed
in and shows an Apple Development certificate, but the selected Personal Team
cannot create provisioning profiles containing System Extension or DriverKit
capabilities. No Core Audio device was published and no live A3 USB/audio test
was attempted.

## Stable starting point

- A1/A1.5 checkpoint: `329c00b Complete Twitch audio transport characterization`
- Controller checkpoint: `b2d4bce Complete Twitch bidirectional Mixxx integration`
- Device: USB `0x1235:0x0018`, interface 0 only for audio
- Core Audio name planned: `Novation Twitch Modern Audio`
- Output channels: MASTER Left, MASTER Right, CUE Left, CUE Right
- Rates: 44,100 and 48,000 Hz
- Capture publication: deferred
- Existing controller sources changed: no
- A3 access to the physical Twitch: none

## Local toolchain enablement

On 2026-08-11 the user installed Xcode 26.6 (build `17F113`) and ran:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

The active toolchain was then measured as:

- developer directory: `/Applications/Xcode.app/Contents/Developer`;
- `xcodebuild`: Xcode 26.6, build `17F113`;
- macOS SDK: `MacOSX26.5.sdk`, version 26.5;
- DriverKit platform SDK: `DriverKit25.5.sdk`, version 25.5;
- AudioDriverKit and USBDriverKit headers, `.iig` definitions and link
  interfaces present under the DriverKit SDK;
- `iig` present at
  `XcodeDefault.xctoolchain/usr/bin/iig`.

The current Apple sample compiled unsigned first. The repository-local dext and
containing macOS app then both built successfully with
`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`. The built app embeds
`com.twitchmodern.NovationTwitchModernAudio.Driver.dext` under
`Contents/Library/SystemExtensions`.

The final product is a universal arm64/x86_64 DriverKit executable linked to
USBDriverKit, AudioDriverKit and DriverKit. The static analyzer reports three
ownership warnings (the retained sample custom-user-client creation plus the
output-buffer and endpoint-pipe ownership transfers). They are not compile
errors, but must be resolved or justified before activation.

The original CLI check reported no usable signing identity. That observation was
superseded after Xcode account sign-in: Xcode displayed an Apple Development
certificate for the user's Personal Team. Automatic signing then failed with
explicit diagnostics that Personal Teams do not support the System Extension,
DriverKit, DriverKit Allow Any UserClient, Audio Family, or USB Transport
capabilities, and no matching development profiles could be created. No Twitch
Modern system extension is installed; the unsigned dext was not activated.

## Pre-installation feasibility gate (historical)

The following records why full Xcode was requested before it was installed. It
is retained as toolchain provenance and is superseded operationally by the
successful build above.

The active developer directory was `/Library/Developer/CommandLineTools`.
`xcodebuild -version` fails because the active directory is a Command Line Tools
installation, not Xcode. The CLT macOS 26.5 SDK does contain base
`DriverKit.framework` headers and a linker stub, and CLT supplies
`libclang_rt.driverkit.a`. It does **not** contain:

- the `DriverKit.platform` platform SDK;
- `AudioDriverKit.framework` development headers/module/link interface;
- `USBDriverKit.framework` development headers/module/link interface;
- the IOKit Interface Generator (`iig`);
- a usable `xcodebuild` implementation (the `/usr/bin/xcodebuild` shim requires
  an Xcode developer directory).

`xcrun --sdk driverkit --show-sdk-path` fails because no DriverKit SDK is
registered. Only `MacOSX15.4.sdk` and `MacOSX26.5.sdk` are installed under CLT.
The operating system has runtime marker bundles for AudioDriverKit and
USBDriverKit under `/System/DriverKit`, but those bundles contain no headers,
module maps, link stubs or standalone binaries and are not development SDKs.

The keychain reports `0 valid identities found` for code signing. No local
provisioning profiles were found.

Consequently the machine could not then compile the dext sources, validate
current SDK signatures, or embed the dext in a host app. Xcode installation has
resolved those build limitations; signing and activation remain blocked.

The project safety rule forbids disabling SIP or security validation as a
development workaround. No such change was attempted.

### Standalone-installation determination

No currently supported Apple mechanism installs the required AudioDriverKit and
USBDriverKit development SDKs independently of Xcode:

- Apple's standalone **Command Line Tools for Xcode** package is documented as
  the macOS SDK plus UNIX-style toolchain/man pages. The installed current CLT
  package confirms the specialized DriverKit family SDKs and `iig` are absent.
- `softwareupdate --list` offers only the current macOS update on this host; it
  exposes no DriverKit or family-framework package.
- Apple's Xcode component manager and `xcodebuild -downloadPlatform` support
  simulator runtimes for iOS/watchOS/tvOS/visionOS. `-downloadComponent`
  currently documents the optional Metal toolchain. DriverKit is not a supported
  downloadable platform/component in either mechanism, and those commands
  themselves require a selected full Xcode installation.
- Apple Developer Downloads provides Xcode and the separate Command Line Tools
  package. Apple does not document or publish a standalone DriverKit,
  AudioDriverKit or USBDriverKit SDK package.

Apple's current SDK matrix lists **DriverKit 25.5 as an SDK included with Xcode
26.5/26.6**, alongside the macOS 26.5 SDK. The differing version number is
Apple's current naming; there is no separately named “DriverKit 26.5” package.

The components required from the full Xcode bundle are therefore:

1. `DriverKit.platform/Developer/SDKs/DriverKit25.5.sdk`, including the
   AudioDriverKit and USBDriverKit framework headers, module metadata and link
   interfaces;
2. the `iig` compiler used to generate DriverKit RPC/dispatch glue from `.iig`
   declarations;
3. Xcode's driver-extension target templates and build rules that compile for
   the DriverKit platform and embed a dext in
   `Contents/Library/SystemExtensions`;
4. the real `xcodebuild` tool used for the app+dext build, signing and packaging
   workflow;
5. Xcode's account/signing/provisioning integration for the host app and dext.

Installing full Xcode is genuinely required for the supported local A3 build.
Copying SDK directories out of an Xcode archive or assembling a synthetic SDK
could be made to work mechanically, but Apple does not document that as a
supported installation and it would not remove signing/entitlement requirements.

## Current Apple architecture finding

Current Apple documentation still makes AudioDriverKit the direct physical-
device path to Core Audio HAL. A driver subclasses `IOUserAudioDriver`, creates
an `IOUserAudioDevice` and output `IOUserAudioStream`, and is shipped inside a
macOS app that activates the dext through SystemExtensions.

Apple's current sample explicitly says a physical audio driver may communicate
with USB hardware with the appropriate transport entitlement. USBDriverKit
supports custom/non-class-compliant devices and provides `IOUSBHostInterface`,
`IOUSBHostPipe`, standard control requests, alternate selection and USB frame
time. This is applicable to Twitch interface 0.

A generic DriverKit article also contains a sentence saying DriverKit does not
support USB devices that manipulate audio. That sentence conflicts with the
AudioDriverKit sample and WWDC AudioDriverKit guidance for physical USB/PCI
transports. The framework-specific sources are treated as authoritative for this
design. No AudioServerPlugIn fallback has been introduced.

## Official Apple sample provenance and license

- Documentation: `Creating an audio device driver`
- Raw archive:
  `https://docs-assets.developer.apple.com/published/8fa6bc52317e/CreatingAnAudioDeviceDriver.zip`
- Downloaded archive SHA-256:
  `f6b31da728498c86e59557392b911915eba80922675cd9f8b7878f87fc3457c0`
- Embedded sample Git commit:
  `ed3da69b379b8753b29d740d692cfaf3aab6ec9d`
- Sample commit date: 2024-08-05
- License: permissive MIT-style grant; Apple copyright and permission notice
  must accompany copied/substantial sample portions

The attributed sample structure is now adapted under
`A3/NovationTwitchModernAudio/`; its permission notice is retained in
`LICENSE.txt`. It has been compiled against the installed SDK but not executed
or activated.

## Implemented playback boundary

`TwitchA3Core` is a small C target suitable for reuse by the future C++ dext. It
does not call Core Audio or USB APIs.

It implements:

- four-channel interleaved Float32 to signed packed-24 little-endian conversion;
- clipping of `+1.0` to `0x7fffff` and `-1.0` to `0x800000`;
- deterministic zero for NaN and infinities;
- preserved channel order 1, 2, 3, 4;
- exact 48-frame-per-millisecond cadence at 48 kHz;
- exact 900 × 44 / 100 × 45 frame cadence per second at 44.1 kHz;
- a caller-storage bounded four-channel ring;
- partial-write overrun accounting;
- packet render with deterministic silence and underrun accounting;
- maximum packet validation against the measured 588-byte endpoint limit.

The ring is intentionally transport-independent and not internally synchronized.
The future dext must serialize producer/consumer access or provide an appropriate
real-time-safe SPSC wrapper after the AudioDriverKit callback execution model is
verified against the installed SDK.

Deterministic test result:

`twitch-a3-tests: cadence, conversion, channel order, ring bounds, wrap and underrun passed`

The full Swift package, existing controller/parser tests and A1 audio tests also
continue to build and pass.

## Implemented unsigned dext/app scaffold

The scaffold currently compiles and provides:

- a containing macOS app with the System Extensions activation UI and embedded
  dext;
- exact IOKit matching for `IOUSBHostInterface`, vendor 4661, product 24,
  configuration 1, interface 0;
- an `IOUserAudioDriver` and playback-only `IOUserAudioDevice` named
  `Novation Twitch Modern Audio`;
- one four-channel interleaved Float32 output stream at 44.1/48 kHz, with
  channels 1/2 designated MASTER and 3/4 designated CUE;
- USBDriverKit provider type validation, interface open, alt-1 selection and
  endpoint `0x01` acquisition in `StartIO`;
- endpoint release, alt-0 restoration and interface close in failure/stop/free
  paths;
- linkage of the deterministic `TwitchA3Core` packetizer.

The scaffold deliberately does not yet submit isochronous requests or issue the
endpoint sample-rate controls. Its AudioDriverKit callback is a no-op until the
bounded producer/USB scheduler is implemented. It must not be activated in this
intermediate state.

### Remaining implementation responsibilities

Host application responsibilities:

- embed the Driver Extension in `Contents/Library/SystemExtensions`;
- request activation/deactivation with `OSSystemExtensionManager`;
- report approval, replacement and activation failures;
- contain no Twitch audio transport loop.

Driver Extension responsibilities:

- subclass `IOUserAudioDriver` and match only `IOUSBHostInterface` 0 for
  `idVendor=4661`, `idProduct=24`, configuration 1;
- create one playback-only `IOUserAudioDevice` named
  `Novation Twitch Modern Audio`;
- create one four-channel output `IOUserAudioStream` with 44.1/48 kHz formats;
- expose USB transport type and MASTER/CUE channel labels;
- map the AudioDriverKit output buffer and feed the tested `TwitchA3Core`
  packetizer;
- issue only the established endpoint-class `SET_CUR`/`GET_CUR` requests;
- select interface 0 alternate 1 in `StartIO`, open endpoint `0x01`, and schedule
  bounded isochronous OUT requests;
- cancel/drain requests and restore alternate 0 in `StopIO` and removal paths;
- leave interface 1 unmatched and unowned;
- publish no input stream and submit no `0x82` request in A3.

The dext must keep three timing quantities distinct:

1. AudioDriverKit ring/buffer duration and safety offset;
2. reported stream/device latency;
3. USB scheduling lead/horizon.

No A3 values are reported yet because no AudioDriverKit callback or USBDriverKit
scheduling behavior has been measured. A1.5's 64 USB-frame horizon is the safe
initial implementation bound, not the Core Audio latency declaration.

## Required signing and entitlements

At minimum, the host app needs the System Extension installation entitlement.
The driver needs a provisioning profile whose approved group contains:

- `com.apple.developer.driverkit`
- `com.apple.developer.driverkit.family.audio`
- `com.apple.developer.driverkit.allow-any-userclient-access` as required by the
  current Apple AudioDriverKit sample/HAL path
- `com.apple.developer.driverkit.transport.usb`, restricted to device descriptor
  fields `idVendor=0x1235` and `idProduct=0x0018`

The transport entitlement is an array of device-descriptor dictionaries. The
IOKit personality must additionally restrict matching to configuration 1 and
interface number 0. A valid Apple Development identity and separate explicit
App IDs/profiles for the host and dext are required.

Because vendor `0x1235` belongs to the original hardware vendor, Apple may
require additional justification or vendor authorization before granting the
USB transport entitlement to this development team. That is an external
approval risk, not yet resolved.

## Validation status

- AudioDriverKit objects: compiled driver, device and four-channel output stream;
  not instantiated because the dext was not activated
- USBDriverKit match/ownership: not tested
- Core Audio device creation: not attempted
- Four output channels visible: not tested
- 44.1/48 kHz selection: stream declarations and core cadence compile/test;
  HAL selection not live-tested
- Stream format conversion: deterministic boundary tests passed
- USB scheduler lead: A1.5 evidence only; no DriverKit measurement
- Zero timestamp: sample-derived timer implementation compiles; not measured
- Safety offset/stream latency: not implemented/measured
- Mixxx MASTER/CUE routing: A1.5 physical mapping proven; Core Audio path not tested
- Controller coexistence with dext: not tested
- Stop/unplug behavior with dext: not tested
- Static analyzer: three ownership warnings remain; no compiler/linker errors
- Legacy driver executed/installed: no
- System extension installed: no
- Security settings changed: no

## Files changed in A3 so far

- `Package.swift`
- `Sources/TwitchA3Core/include/TwitchA3Core.h`
- `Sources/TwitchA3Core/TwitchA3Core.c`
- `Sources/TwitchA3Tests/main.swift`
- `A3_STATUS.md`
- `AUDIO_ARCHITECTURE.md`
- `AUDIO_STATUS.md`
- `A3/NovationTwitchModernAudio/` (attributed app+dext scaffold and license)

## Required next actions

1. Select an eligible Apple Developer Program team in Xcode. The current
   Personal Team is proven insufficient even though its Apple Development
   certificate exists.
2. Request one DriverKit entitlement group containing Audio Family, USB transport
   for `0x1235:0x0018`, and the HAL user-client entitlement required by the
   current sample.
3. Create explicit host-app and dext App IDs and development profiles after Apple
   grants the group.
4. Before activation, finish and review endpoint sample-rate control, bounded
   isochronous scheduling/cancellation, AudioDriverKit ring consumption and
   unplug handling.
5. Only after a signed build activates successfully, perform the required silent
   physical safety gate and live Mixxx validation.

Do not use SIP disablement, `systemextensionsctl developer on`, ad-hoc signing or
an AudioServerPlugIn to bypass these prerequisites.
