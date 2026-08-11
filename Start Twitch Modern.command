#!/bin/sh

set -u

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

"$project_dir/scripts/run-controller.sh" || {
    status=$?
    printf '\nStartup did not complete. Press Return to close this window.\n'
    read -r ignored
    exit "$status"
}
