# AudioDriverKit contributor brief

## Current boundary

The target is a playback-only Core Audio device named
`Novation Twitch Modern Audio` with four output channels:

1. MASTER Left
2. MASTER Right
3. CUE Left
4. CUE Right

It must support 44.1 and 48 kHz. Capture publication is deferred.

The A3 project compiles unsigned against Xcode 26.6 / DriverKit 25.5. It already
contains exact interface-0 matching, AudioDriverKit device/stream declarations,
USB open/alt/endpoint/restore scaffolding, and a deterministic Float32-to-packed
24-bit conversion/ring core. It does not yet submit isochronous requests or
perform endpoint sample-rate control and must not be activated as-is.

## Entitlement blocker

The tested Personal Team can create an Apple Development certificate but cannot
provision System Extension or DriverKit capabilities. A contributor needs an
eligible Apple Developer Program team and an Apple-approved entitlement group
covering:

- `com.apple.developer.driverkit`
- `com.apple.developer.driverkit.family.audio`
- `com.apple.developer.driverkit.transport.usb` restricted to VID `0x1235`, PID
  `0x0018`
- the Audio HAL user-client permission required by the final design
- host-app System Extension installation capability

Apple ties approved entitlements to a development team. Vendor ownership of VID
`0x1235` may require additional justification or authorization.

Apple's supported process is documented in
[Requesting Entitlements for DriverKit Development](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development).

## Stewardship and entitlement-request intent

The Twitch is Novation/Focusrite hardware. Its industrial design, firmware,
trademarks, USB vendor ID `0x1235`, and product identity remain associated with
the original manufacturer; ownership of an individual physical unit remains
with that unit's owner. This is an unofficial community project and does not
claim endorsement, authorization, or ownership from Novation or Focusrite.

Any Apple entitlement request made for this project must be accurate and should
state plainly that:

- the Twitch is discontinued legacy hardware whose original macOS driver no
  longer supports current Apple-silicon systems;
- the purpose is preservation: keeping functional controllers useful and out of
  landfills rather than forcing otherwise-unnecessary hardware replacement;
- the implementation and controller access are free and open source, with no
  payment required for software, features, or support;
- the project is not attempting to sell, relabel, impersonate, or take control
  of Novation/Focusrite hardware or intellectual property;
- the requested USB transport scope is narrowly limited to Twitch VID
  `0x1235`, PID `0x0018`, audio interface 0; and
- the project welcomes coordination with Novation/Focusrite and will respect any
  legitimate technical, trademark, or authorization requirements they identify.

This preservation rationale must not be used to conceal relevant facts or imply
that Apple approval is automatic. Optional tips support community work but do
not purchase access and should not be characterized as payment for the driver.

## Remaining implementation

- Resolve or justify all static-analyzer ownership warnings.
- Implement established endpoint-class sample-rate `SET_CUR`/`GET_CUR`.
- Feed the proven packetizer from the AudioDriverKit output ring.
- Implement bounded future-frame USB scheduling and cancellation.
- Keep AudioDriverKit buffer duration, reported latency/safety offset, and USB
  scheduling lead as separate measured quantities.
- Drain/cancel safely on StopIO and removal; restore interface 0 to alt 0.
- Leave interface 1 available to the stable controller bridge.
- Publish no input stream and submit no `0x82` request in the first version.

## Live acceptance gate

Before output: MASTER down, BOOTH down, headphones down, powered speakers off.
Begin with silence. The milestone passes only when Audio MIDI Setup exposes four
outputs at both rates, Mixxx MASTER/CUE routing is correct, sustained playback is
clean, controller input/LED output coexist, and stop/unplug restores ownership.

Do not bypass signing with SIP disablement, reduced-security boot, or ad-hoc
DriverKit activation. Apple's current entitlement workflow is linked from the
historical A3 status and audio architecture documents.
