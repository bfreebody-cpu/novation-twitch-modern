# Experimental audio dependency provenance

This file covers only the AudioServerPlugIn experiment tracked in Issue #5.

## Apple NullAudio sample

- Purpose: current API and behavioral authority for a minimal AudioServerPlugIn
- Documentation: https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in
- Download: `https://docs-assets.developer.apple.com/published/430ad6501f6f/CreatingAnAudioServerDriverPlugIn.zip`
- Download SHA-256: `860334dfa9e83f2afb749a890ca5a79fc7d3d572d4e116ff9242bec458be4cb0`
- Embedded sample Git commit: `88460220d88e9d5f2230bcbc5f11a0655f351dd5`
- Sample commit date: 2024-11-01
- License: Apple's permissive sample license (MIT-form text)
- Copied into this experiment: no

The sample was inspected to confirm the current HAL plug-in structure, 44.1/48
kHz format behavior, installation location, and AudioServerPlugIn lifecycle.

## libASPL

- Upstream: https://github.com/gavv/libASPL
- Exact commit: `633e0f70203edd87d320fc5a3cae901e1363aac5`
- Release associated with commit: `v3.1.2`
- Commit date: 2025-04-14
- License: MIT
- Purpose: AudioServerPlugIn object/property dispatch, Core Audio lifecycle,
  stream publication, and timestamp boilerplate
- Acquisition: CMake FetchContent at the exact commit above
- Local modifications: none

libASPL does not implement Twitch USB access. Project code remains responsible
for device identity, channel/rate declarations, real-time sample handling, and
all later Twitch transport behavior.

## DJM-T1 driver

- Upstream: https://github.com/yuki-ama/djm-t1-driver
- Inspected commit: `90c09d72bd6f6b5cbe218fe73e4b76f31cfd9061`
- License: MIT (repository); third-party components retain their own licenses
- Purpose: architecture precedent only for a USB helper, shared-memory ring, and
  AudioServerPlugIn split used with discontinued DJ hardware
- Copied into this experiment: no

No DJM-T1 packet sizes, USB commands, retry behavior, latency declarations, or
device-specific source are to be copied into the Twitch implementation.

## System-broker API authority

The B0 broker architecture in
[`BROKER_RESEARCH_STATUS.md`](BROKER_RESEARCH_STATUS.md) relies on platform APIs
and contracts rather than an additional third-party dependency:

- Apple QA1811, `AudioServerPlugIn_MachServices` behavior:
  https://developer.apple.com/library/archive/qa/qa1811/
- Apple XPC API documentation, including Mach-service connections, peer
  requirements, anonymous endpoints, and shared-memory objects:
  https://developer.apple.com/documentation/xpc
- Apple TN3127, code-signing requirement construction and the limitations of
  ad-hoc identities:
  https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- Apple `SMAppService`, current app-managed LaunchDaemon registration and
  notarization contract:
  https://developer.apple.com/documentation/servicemanagement/smappservice
- macOS 26.5 SDK headers and the `launchctl(1)` / `launchd.plist(5)` manual
  pages installed with Xcode 26.6 and macOS 26.5.2.

No Apple sample source or third-party broker code was copied during B0.
