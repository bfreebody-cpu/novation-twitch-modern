#!/bin/sh
set -eu

cat >&2 <<'EOF'
STOP: helper restart testing is blocked because the installed Core Audio host
cannot discover the GUI-domain LaunchAgent. No initial HAL-to-helper connection
exists to restart. See audio/PHASE2_STATUS.md.
EOF
exit 1
