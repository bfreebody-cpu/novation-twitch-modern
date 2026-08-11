# Contributing

Contributions are welcome, especially controller packaging, documentation,
tests, and completion of the playback-only AudioDriverKit path.

## Ground rules

- Preserve exact USB matching for `0x1235:0x0018`.
- Keep controller transport, Core MIDI publication, Mixxx mapping, and audio
  transport as separate concerns.
- Do not replace measured hardware behavior with assumptions from documentation.
- Do not use vendor-specific USB requests without new evidence and review.
- Never require disabling SIP, reduced-security boot, or other weakened macOS
  protections for ordinary use.
- Do not commit proprietary Novation binaries/manuals, raw personal captures,
  signing identities, provisioning profiles, or Apple team identifiers.
- Preserve the Apple notice in `A3/NovationTwitchModernAudio/LICENSE.txt` and
  source headers.

## Building and testing

```sh
swift build
swift run twitch-parser-tests
swift run twitch-a1-tests
swift run twitch-a3-tests
swift mapping/novation-twitch-modern/test-mapping.swift
jq empty control-inventory/*.json
```

Most tests are USB-independent. Hardware changes should include bounded capture
evidence and must state which claims are documented, observed, inferred, or
still hypothetical.

## Audio-driver contributions

Start with [docs/AUDIO_CONTRIBUTORS.md](docs/AUDIO_CONTRIBUTORS.md). Do not
activate the current scaffold merely because it compiles. A live pull request
must explain signing/entitlement scope, interface ownership, request
cancellation, alt-0 restoration, and the physical low-level safety procedure.

## Pull requests

Keep changes focused, add regression coverage, run all deterministic checks, and
describe any physical-device testing precisely. Avoid checking in generated
build products or full raw captures; attach a redacted summary instead.
