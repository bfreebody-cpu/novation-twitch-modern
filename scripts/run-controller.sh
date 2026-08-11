#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
installer="$script_dir/install-mixxx-mapping.sh"
check_only=false

case "${1:-}" in
    --check)
        check_only=true
        shift
        ;;
    -h|--help)
        printf '%s\n' \
            "Usage: $0 [--check]" \
            "" \
            "Build and start the controller-only Twitch bridge." \
            "Use --check to validate the setup and build without opening USB."
        exit 0
        ;;
esac

if [ "$#" -ne 0 ]; then
    printf 'Unexpected argument. Run %s --help for usage.\n' "$0" >&2
    exit 2
fi

if [ "$(uname -s)" != "Darwin" ]; then
    printf 'Novation Twitch Modern currently supports macOS only.\n' >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    printf '%s\n' \
        "Swift was not found." \
        "Install current Xcode or Command Line Tools, then try again." >&2
    exit 1
fi

target_dir=$($installer --print-target)
xml_name="Novation Twitch Modern.midi.xml"
js_name="Novation-Twitch-Modern-scripts.js"

for filename in "$xml_name" "$js_name"; do
    canonical="$repo_root/mapping/novation-twitch-modern/$filename"
    installed="$target_dir/$filename"

    if [ ! -f "$installed" ]; then
        printf '%s\n' \
            "The Mixxx mapping is not installed:" \
            "  $installed" \
            "" \
            "Run this once, then start the controller again:" \
            "  $installer" >&2
        exit 1
    fi

    if ! cmp -s "$canonical" "$installed"; then
        printf '%s\n' \
            "The installed Mixxx mapping is older or locally modified:" \
            "  $installed" \
            "" \
            "Run the safe installer to back it up and install this version:" \
            "  $installer" >&2
        exit 1
    fi
done

if pgrep -if '/Mixxx.app/Contents/MacOS/mixxx' >/dev/null 2>&1; then
    printf '%s\n' \
        "Mixxx is already running." \
        "Quit Mixxx completely, start this bridge, and then reopen Mixxx." >&2
    exit 1
fi

printf '%s\n' \
    "Novation Twitch Modern controller launcher" \
    "" \
    "This starts controller MIDI and LED support only." \
    "It does not open Twitch audio endpoints." \
    "" \
    "Building the controller bridge..."

cd "$repo_root"
swift build --product twitch-m4

bridge="$repo_root/.build/debug/twitch-m4"
if [ ! -x "$bridge" ]; then
    printf 'Build completed but the bridge was not found at %s\n' "$bridge" >&2
    exit 1
fi

if $check_only; then
    printf '%s\n' \
        "" \
        "Setup check passed." \
        "The mapping is current and the controller bridge builds successfully." \
        "No USB device was opened."
    exit 0
fi

printf '%s\n' \
    "" \
    "Starting Novation Twitch Modern." \
    "Wait for the bridge-running message, then open Mixxx." \
    "Keep this Terminal window open while using the controller." \
    "Press Control-C here to stop safely." \
    ""

exec "$bridge" --mode m4-bridge
