#!/bin/sh
set -eu

cat >&2 <<'EOF'
STOP: the installed 0.3.0 test established that the isolated Core Audio driver
host resolves this Mach service in the system bootstrap domain, while the
unprivileged helper is registered only in the logged-in user's GUI domain.
launchd returns "No such process" and the helper never starts.

This live test is retired so it cannot report Core Audio's fail-open callbacks
as successful bridge delivery. See audio/PHASE2_STATUS.md. Do not move the
helper to a root LaunchDaemon or weaken shared-memory permissions without a new
reviewed architecture decision.
EOF
exit 1
