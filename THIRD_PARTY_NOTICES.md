# Third-party notices

## Historical Mixxx mapping

The current controller mapping was adapted using the Novation Twitch mapping
shipped in Mixxx 2.3.6 as behavioral reference. That historical mapping contains
code licensed GPL version 3 or later by Juan Pedro Bolívar Puente. Accordingly,
the public project's adapted mapping and original code are distributed under
GPL-3.0-or-later. The historical bundle itself is not vendored here; exact
provenance and blob hashes are in `reference/mixxx/MANIFEST.md`.

## Apple AudioDriverKit sample

`A3/NovationTwitchModernAudio/` is structurally adapted from Apple's “Creating
an audio device driver” sample. Apple's copyright and permissive permission
notice is retained at `A3/NovationTwitchModernAudio/LICENSE.txt` and in adapted
source headers. That notice governs Apple-originated sample portions.

## Experimental AudioServerPlugIn research

The experimental HAL feasibility probe uses libASPL at commit
`633e0f70203edd87d320fc5a3cae901e1363aac5`. libASPL is copyright Victor
Gaydov and contributors and is distributed under the MIT License. Exact
provenance and its role are recorded in `audio/DEPENDENCIES.md`.

Apple's “Creating an Audio Server Driver Plug-in” sample was inspected as the
current API and behavioral authority. No sample source is copied into the probe.

## Linux kernel source

Linux USB-audio source at commit
`db2ddb87143519e20a95aa36c60b36107b736a58` was used as behavioral evidence.
The source snapshots are not redistributed in this public tree. Their upstream
paths, Git blob IDs, roles, and SPDX identifiers are documented in
`reference/linux/MANIFEST.md`. No Linux kernel code was copied into the macOS
implementation.

## Novation documentation and legacy drivers

The Novation Twitch user/programmer manuals and two historical Novation driver
DMGs were inspected as evidence but are not redistributed. They remain the
property of their respective rights holders. Integrity hashes are recorded in
`reference/README.md`.
