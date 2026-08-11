# Novation Twitch Modern Audio — A3 prototype

This is the playback-only AudioDriverKit/USBDriverKit prototype container for
the Novation Twitch (`0x1235:0x0018`), interface 0. It is based structurally on
Apple's “Creating an audio device driver” sample at commit
`ed3da69b379b8753b29d740d692cfaf3aab6ec9d`. The accompanying Apple permission
notice is retained in `LICENSE.txt` and in adapted source headers.

The project is intentionally not installable with ad-hoc signing. A signed live
build requires an Apple Development identity, explicit host and dext App IDs,
profiles containing the AudioDriverKit and restricted USB transport entitlement,
and normal System Settings approval.

An unsigned compile-only check is safe and performs no installation:

```sh
xcodebuild \
  -project SimpleAudioDriverExtension.xcodeproj \
  -scheme SimpleAudioDriver \
  -configuration Debug \
  -derivedDataPath /tmp/twitch-a3-derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Do not activate this prototype until its USB transport, bounded isochronous
scheduler, rate-control lifecycle, and stop/unplug paths are complete and the
A3 safety gate has been reviewed.
