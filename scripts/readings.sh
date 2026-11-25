#!/bin/sh
# Prints the text readings the app wrote to the macOS log in the last few minutes.
# This is how a coding agent reads what the app saw while a person was using it.
#
# Usage: scripts/readings.sh [minutes]     (default 10)
#
# Lines hold numbers and label names only, and exist only while "Share readings with the
# coding agent" is ticked in the app.
set -eu
MINUTES=${1:-10}
case "$MINUTES" in ''|*[!0-9]*) echo "usage: scripts/readings.sh [minutes]" >&2; exit 2 ;; esac
/usr/bin/log show --last "${MINUTES}m" --info --style compact \
    --predicate 'subsystem == "com.local.FocusAssistant" AND category == "shared"' 2>/dev/null \
    | sed -n 's/^[0-9-]* \([0-9:]*\)[.0-9]* .*\] \(.*\)$/\1 \2/p'
