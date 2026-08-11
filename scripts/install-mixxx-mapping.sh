#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
mapping_dir="$repo_root/mapping/novation-twitch-modern"

xml_name="Novation Twitch Modern.midi.xml"
js_name="Novation-Twitch-Modern-scripts.js"
dry_run=false
print_target=false

usage() {
    printf '%s\n' \
        "Usage: $0 [--dry-run] [--print-target]" \
        "" \
        "Installs the Novation Twitch Modern mapping into the current user's" \
        "Mixxx controller directory. Differing existing files are backed up." \
        "" \
        "For testing or a nonstandard Mixxx installation, set:" \
        "  MIXXX_CONTROLLERS_DIR=/absolute/path/to/controllers"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            dry_run=true
            ;;
        --print-target)
            print_target=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ -n "${MIXXX_CONTROLLERS_DIR:-}" ]; then
    target_dir=$MIXXX_CONTROLLERS_DIR
else
    sandbox_root="$HOME/Library/Containers/org.mixxx.mixxx/Data/Library/Application Support/Mixxx"
    regular_root="$HOME/Library/Application Support/Mixxx"

    if [ -d "$sandbox_root" ] || [ ! -d "$regular_root" ]; then
        target_dir="$sandbox_root/controllers"
    else
        target_dir="$regular_root/controllers"
    fi
fi

case "$target_dir" in
    /*) ;;
    *)
        printf 'Refusing a non-absolute controller directory: %s\n' "$target_dir" >&2
        exit 1
        ;;
esac

if [ "$target_dir" = "/" ] || [ "$target_dir" = "$HOME" ]; then
    printf 'Refusing unsafe controller directory: %s\n' "$target_dir" >&2
    exit 1
fi

if $print_target; then
    printf '%s\n' "$target_dir"
    exit 0
fi

for source_file in "$mapping_dir/$xml_name" "$mapping_dir/$js_name"; do
    if [ ! -f "$source_file" ]; then
        printf 'Required mapping source is missing: %s\n' "$source_file" >&2
        exit 1
    fi
done

timestamp=$(date -u '+%Y%m%dT%H%M%SZ')

if $dry_run; then
    printf 'Dry run; target directory: %s\n' "$target_dir"
else
    mkdir -p "$target_dir"
fi

install_one() {
    source_file=$1
    filename=$2
    target_file="$target_dir/$filename"

    if [ -f "$target_file" ] && cmp -s "$source_file" "$target_file"; then
        printf 'Already current: %s\n' "$target_file"
        return
    fi

    if [ -e "$target_file" ]; then
        backup_file="$target_file.backup-$timestamp"
        suffix=1
        while [ -e "$backup_file" ]; do
            backup_file="$target_file.backup-$timestamp-$suffix"
            suffix=$((suffix + 1))
        done

        if $dry_run; then
            printf 'Would back up: %s\n' "$target_file"
            printf '           to: %s\n' "$backup_file"
        else
            cp -p "$target_file" "$backup_file"
            printf 'Backed up: %s\n' "$backup_file"
        fi
    fi

    if $dry_run; then
        printf 'Would install: %s\n' "$target_file"
    else
        temporary_file="$target_file.tmp.$$"
        trap 'rm -f "$temporary_file"' EXIT HUP INT TERM
        cp "$source_file" "$temporary_file"
        chmod 0644 "$temporary_file"
        mv -f "$temporary_file" "$target_file"
        trap - EXIT HUP INT TERM
        printf 'Installed: %s\n' "$target_file"
    fi
}

install_one "$mapping_dir/$xml_name" "$xml_name"
install_one "$mapping_dir/$js_name" "$js_name"

if $dry_run; then
    printf '%s\n' "" "Dry run complete. No files were changed."
else
    printf '%s\n' \
        "" \
        "Mapping installation complete." \
        "Next: close Mixxx, connect the Twitch, and run:" \
        "  $repo_root/scripts/run-controller.sh"
fi
