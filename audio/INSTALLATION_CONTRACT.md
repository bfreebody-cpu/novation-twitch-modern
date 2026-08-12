# Experimental HAL probe installation contract

This contract applies only to the USB-independent Phase 1 feasibility probe.

## Payload

The installer may create exactly one system payload:

```text
/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver
```

Expected bundle identifier:

```text
com.twitchmodern.NovationTwitchModernAudioExperimental
```

It installs no USB helper, daemon, launch item, Driver Extension, kernel
extension, package receipt, preference file, or legacy Novation component.

## Installation behavior

- Requires an already-built bundle.
- Requires explicit administrator authorization.
- Refuses to replace an existing path, even if it appears project-owned.
- Verifies the bundle identifier before copying.
- Copies only to the exact path above.
- Sets conventional root ownership on the installed copy.
- Verifies the installed code signature.
- Restarts Core Audio so it can discover the plug-in.

Installation does not access the Twitch and does not change macOS security
settings.

## Uninstall behavior

- Requires explicit administrator authorization.
- Resolves only the exact path above.
- Refuses removal unless the installed bundle identifier exactly matches.
- Removes the one project-owned bundle.
- Restarts Core Audio.

If validation fails, the script stops and asks for manual inspection. It does
not broaden the deletion target.

## Recovery

If Core Audio behaves unexpectedly after installation, run the project uninstall
script and reboot. Do not disable SIP or enable Reduced Security.
