# Experimental HAL probe installation contract

This contract applies to the USB-independent Phase 1 and Phase 2 probes.

## Payload

The administrator-authorized installer may create exactly one system payload:

```text
/Library/Audio/Plug-Ins/HAL/NovationTwitchModernAudioExperimental.driver
```

Expected bundle identifier:

```text
com.twitchmodern.NovationTwitchModernAudioExperimental
```

The bundle contains the project-built XPC helper executable as a resource. It
does not install a LaunchDaemon, privileged helper, Driver Extension, kernel
extension, package receipt, preference file, or legacy Novation component.

The logged-in-user installer may additionally create exactly one user payload:

```text
~/Library/LaunchAgents/com.twitchmodern.NovationTwitchModernAudioExperimental.bridge.plist
```

This LaunchAgent advertises one named Mach service and starts the embedded
helper on demand. The helper runs as the logged-in user, never as root. It owns
one anonymous, bounded shared-memory mapping containing audio frames and
counters only. The mapping is handed only to an XPC peer whose effective UID is
`_coreaudiod`; there is no named or world-writable shared-memory object in the
installed path.

## Installation behavior

- Requires an already-built bundle.
- Requires explicit administrator authorization.
- Refuses to replace an existing path, even if it appears project-owned.
- Verifies the bundle identifier before copying.
- Copies only to the exact path above.
- Sets conventional root ownership on the installed copy.
- Verifies the installed code signature.
- Requires the separate user-level `install-xpc-agent.sh` step, run without
  `sudo`. That script refuses existing files/services, copies only the embedded
  reviewed plist, adds user-owned log paths under
  `~/Library/Logs/NovationTwitchModern`, validates the plist, and registers it
  in the current GUI launchd domain. The service emits one metrics snapshot per
  minute while running; uninstall preserves those logs as test evidence.
- Requires a normal reboot so Core Audio can discover the plug-in. Apple's
  current NullAudio sample also specifies rebooting after installation. On the
  tested macOS 26.5.2 system, attempting to kickstart the protected system
  `coreaudiod` service is rejected while SIP is enabled; the project does not
  weaken SIP or retry through unsupported mechanisms.

Installation does not access the Twitch and does not change macOS security
settings. The correct order is: install the HAL bundle with administrator
authorization, install/register the LaunchAgent as the logged-in user, then
reboot normally.

## Uninstall behavior

- First run `uninstall-xpc-agent.sh` as the logged-in user. It unregisters the
  exact launchd label and removes only its validated plist. It preserves logs.
- Then run the HAL uninstaller with explicit administrator authorization.
- Resolves only the exact path above.
- Refuses removal unless the installed bundle identifier exactly matches.
- Removes the one project-owned bundle.
- Requires a normal reboot so Core Audio unloads the removed plug-in.

The privileged uninstaller deliberately does not inspect or alter users' home
directories and does not execute user-writable build-tree code. Stopping the
LaunchAgent terminates its mapping owner; the reboot unloads the HAL bundle.

If validation fails, the script stops and asks for manual inspection. It does
not broaden the deletion target.

## Recovery

If Core Audio behaves unexpectedly after installation, run the project uninstall
scripts in the documented user-then-root order and reboot. Do not disable SIP or
enable Reduced Security. The scripts do not terminate or kickstart protected
audio services.
