# Beginner guide: use Novation Twitch Modern with Mixxx

This guide gets the Twitch controller working in Mixxx on an Apple-silicon Mac.
No programming knowledge is required, but the current version uses a Terminal
window while you DJ.

## What this gives you

- Twitch controls for decks A and B in Mixxx
- PLAY, CUE, mixer, browser, EQ, trim, touchstrip, pads, loops, and FX controls
- Mixxx-driven button and pad lights

It does **not** make the Twitch sound card appear in Audio MIDI Setup. In Mixxx,
continue using the Mac's speakers/headphone output or another working Core Audio
device. Do not run the engineering programs named `twitch-a1` or `twitch-a1-5`;
those are physical audio research tools.

## Before you begin

You need:

- an Apple-silicon Mac running macOS 15 or newer;
- a Novation Twitch connected directly by USB;
- Mixxx 2.5.6 or a compatible current Mixxx release; and
- current Xcode or Apple's Command Line Tools.

Open Terminal (Applications > Utilities > Terminal) and check for Swift:

```sh
swift --version
```

If Terminal says `command not found`, install Xcode from the App Store, launch it
once so its components finish installing, and try again. Controller support does
not require an Apple Developer account or DriverKit entitlements.

## 1. Download the project

The easiest reliable method is Git. In Terminal:

```sh
cd ~/Documents
git clone https://github.com/bfreebody-cpu/novation-twitch-modern.git
cd novation-twitch-modern
```

If you already downloaded it, open its folder in Finder, type `cd ` (including
the space) in Terminal, drag the project folder into the Terminal window, and
press Return.

## 2. Install the Mixxx mapping once

Quit Mixxx, then run:

```sh
./scripts/install-mixxx-mapping.sh
```

The installer copies only the two mapping files. If different versions already
exist, it preserves timestamped backup copies before replacing them. Running the
installer again is safe; current files are left alone.

To preview its actions without changing anything:

```sh
./scripts/install-mixxx-mapping.sh --dry-run
```

## 3. Start the controller bridge

Make sure Mixxx is closed and the Twitch is connected. Run:

```sh
./scripts/run-controller.sh
```

You can instead double-click `Start Twitch Modern.command` in Finder. If macOS
does not allow the first double-click, use the Terminal command above.

The first build can take a little longer. Keep the Terminal window open. After
the bridge reports that `Novation Twitch Modern` is running, open Mixxx normally.

To check the installation and build without opening the Twitch, use:

```sh
./scripts/run-controller.sh --check
```

## 4. Enable it in Mixxx

1. Open Mixxx Preferences.
2. Select **Controllers**.
3. Select **Novation Twitch Modern** in the device list.
4. Check **Enabled**.
5. Choose the **Novation Twitch Modern** mapping if Mixxx has not selected it.
6. Apply the changes and close Preferences.

Press PLAY on deck A. Mixxx should respond and the Twitch PLAY light should
follow the Mixxx state. Also try CUE, a channel fader, the crossfader, and one hot
cue pad.

## Normal daily use

1. Connect the Twitch.
2. Start `./scripts/run-controller.sh` or double-click the `.command` launcher.
3. Wait for the running message.
4. Open Mixxx.
5. Keep the Terminal window open.

When finished, quit Mixxx first so its mapped lights clear. Then return to the
Terminal window and press Control-C. The bridge releases the device safely.

## If the Twitch is unplugged

The bridge stops safely when the device disappears. Mixxx 2.5.6 does not
automatically rediscover the replacement virtual MIDI endpoints.

Recovery order matters:

1. Reconnect the Twitch.
2. Close Mixxx completely.
3. Start the controller bridge again.
4. Reopen Mixxx.

The enabled mapping should be remembered; you should not need to configure it
again.

## Troubleshooting

### Novation Twitch Modern is missing from Mixxx

- Confirm the bridge Terminal window says it is running.
- Start the bridge before opening Mixxx.
- Quit and reopen Mixxx after any unplug/reconnect or bridge restart.
- Run `./scripts/install-mixxx-mapping.sh` again.
- Check Mixxx Preferences > Controllers and enable the device.

### The bridge cannot find the Twitch

- Disconnect and reconnect the Twitch directly to the Mac rather than through a
  hub.
- Check Apple menu > About This Mac > More Info > System Report > USB. The device
  should show vendor `0x1235` and product `0x0018`.
- Quit Mixxx and any earlier bridge Terminal window, then retry.
- Do not use `sudo`, change macOS security settings, or install the old Novation
  driver.

### The mapping installer says the installed files differ

Run the installer normally. It creates timestamped backups before installing the
current canonical files. The launcher intentionally refuses an unknown mapping
so the tested bridge and mapping stay in sync.

### The lights change when SHIFT is pressed

SHIFT toggles an alternate page; press it again to return. It is not a hold-only
modifier and the Twitch has no deck C/D buttons.

### The first shifted AUTOLOOP pads are extremely fast

That is intentional. They select 1/32, 1/16, 1/8, and 1/4-beat loops. Normal-page
AUTOLOOP begins at 1/2 beat.

### Hot cues change on both decks

If the same track is loaded on both decks, Mixxx shares that track's saved hot
cues. This is Mixxx track metadata, not cross-talk from the controller.

### SLICER does not behave like a native slicer

Mixxx 2.5.6 has no generic native slicer control. The compatibility page uses
pads 1-4 for sampler preview, pad 5 for spinback, pad 6 for brake, and reserves
pads 7-8.

## Updating later

From the project directory:

```sh
git pull
./scripts/install-mixxx-mapping.sh
```

Then use the normal start order again.

## Removing the mapping

Quit Mixxx. The installer prints the exact controller directory it uses:

```sh
./scripts/install-mixxx-mapping.sh --print-target
```

Inside that directory, remove only:

- `Novation Twitch Modern.midi.xml`
- `Novation-Twitch-Modern-scripts.js`

Do not remove the entire Mixxx settings or controllers directory.
