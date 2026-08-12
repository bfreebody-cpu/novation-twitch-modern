# Experimental HAL probe installation contract

This contract applies to the USB-independent Phase 1 and Phase 2 probes.

## Payload

The installer may create exactly one system payload:

```text
/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver
```

Expected bundle identifier:

```text
com.twitchmodern.NovationTwitchModernAudioExperimental
```

It installs no helper executable, daemon, launch item, Driver Extension, kernel
extension, package receipt, preference file, or legacy Novation component.

During Phase 2 runtime, the plug-in or manually launched helper may create the
user-scoped POSIX shared-memory object `/ntm_audio_v1`. It is a bounded runtime
mapping, not an installed system payload. It contains audio frames and counters
only. No process is configured to start persistently.

## Installation behavior

- Requires an already-built bundle.
- Requires explicit administrator authorization.
- Refuses to replace an existing path, even if it appears project-owned.
- Verifies the bundle identifier before copying.
- Copies only to the exact path above.
- Sets conventional root ownership on the installed copy.
- Verifies the installed code signature.
- Requires a normal reboot so Core Audio can discover the plug-in. Apple's
  current NullAudio sample also specifies rebooting after installation. On the
  tested macOS 26.5.2 system, attempting to kickstart the protected system
  `coreaudiod` service is rejected while SIP is enabled; the project does not
  weaken SIP or retry through unsupported mechanisms.

Installation does not access the Twitch and does not change macOS security
settings.

## Uninstall behavior

- Requires explicit administrator authorization.
- Resolves only the exact path above.
- Refuses removal unless the installed bundle identifier exactly matches.
- Removes the one project-owned bundle.
- Removes the exact `/ntm_audio_v1` name when the locally built cleanup helper is
  available; existing process mappings remain valid until those processes stop.
- Requires a normal reboot so Core Audio unloads the removed plug-in.

If validation fails, the script stops and asks for manual inspection. It does
not broaden the deletion target.

## Recovery

If Core Audio behaves unexpectedly after installation, run the project uninstall
script and reboot. Do not disable SIP or enable Reduced Security. The scripts do
not terminate or kickstart protected audio services.
