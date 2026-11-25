#!/bin/sh
# Runs the app by itself for a few seconds with the camera on, then prints what it measured.
# Nobody has to press a button, so a person or a coding agent can run the same check.
#
# Usage: scripts/selftest.sh [seconds] [--sound] [--capture-only] [--guided] [--no-preview] [--no-build]
#   seconds         how long the camera stays on (default 12, allowed 3 to 900)
#   --guided        the spoken guided phone check instead (about 62 s): the app says when to
#                   look at the screen, shift position, use the phone, and labels the readings
#   --no-preview    hide the live picture (for resource measurements)
#   --sound         also name the kind of sound nearby (uses the microphone)
#   --capture-only  camera without analysis, as a baseline for measurements
#   --no-build      use the Debug app already built
#
# It closes any running FocusAssistant first. If macOS has no stored permission for this
# exact build, its camera (or microphone) prompt appears and the run waits up to 90 s for
# Allow. That happens after every rebuild while the app is ad-hoc signed. Nothing is saved
# except text readings (numbers and label names) in the macOS log; they are copied to
# build/selftest-last.txt. Exit status 0 means the run finished.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

RUN_SECONDS=12
GUIDED=0
APP_ARGS=""
BUILD=1
for arg in "$@"; do
    case "$arg" in
        --sound|--capture-only|--no-preview) APP_ARGS="$APP_ARGS $arg" ;;
        --guided) APP_ARGS="$APP_ARGS $arg"; GUIDED=1 ;;
        --no-build) BUILD=0 ;;
        ''|*[!0-9]*) echo "usage: scripts/selftest.sh [seconds] [--sound] [--capture-only] [--guided] [--no-preview] [--no-build]" >&2; exit 2 ;;
        *) RUN_SECONDS=$arg ;;
    esac
done

APP="$ROOT/build/DerivedData/Build/Products/Debug/FocusAssistant.app"
mkdir -p build
if [ "$BUILD" -eq 1 ]; then
    echo "Building…"
    if ! xcodebuild -project FocusAssistant.xcodeproj -scheme FocusAssistant -configuration Debug \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build > build/selftest-build.log 2>&1; then
        echo "BUILD FAILED (full log: build/selftest-build.log)"
        grep -E "error:" build/selftest-build.log | head -20
        exit 1
    fi
fi
[ -d "$APP" ] || { echo "App not built yet: $APP" >&2; exit 1; }
[ "$GUIDED" -eq 1 ] && RUN_SECONDS=62 # Matches GuidedCheck.totalSeconds.

# A small helper that reports whether any camera is switched on, without opening one.
PROBE=build/camera-in-use
if [ ! -x "$PROBE" ] || [ scripts/camera-in-use.swift -nt "$PROBE" ]; then
    swiftc -O -o "$PROBE" scripts/camera-in-use.swift 2> build/camera-in-use-build.log || PROBE=""
fi
camera_state() {
    if [ -n "$PROBE" ]; then "$PROBE" 2>/dev/null || echo unknown; else echo unknown; fi
}

if pgrep -x FocusAssistant > /dev/null; then
    echo "Closing the running FocusAssistant first."
    pkill -x FocusAssistant || true
    sleep 1
fi

BEFORE=$(camera_state)
STARTED=$(date '+%Y-%m-%d %H:%M:%S')
echo "Starting the app: the camera will be on for about $RUN_SECONDS s. If macOS asks for permission, click Allow."
# shellcheck disable=SC2086
open -n "$APP" --args --selftest "$RUN_SECONDS" $APP_ARGS

DURING="not seen on"
WAITED=0
LIMIT=$((RUN_SECONDS + 130)) # Covers the 90 s wait for a permission prompt.
sleep 2
while pgrep -x FocusAssistant > /dev/null; do
    if [ "$WAITED" -ge "$LIMIT" ]; then
        echo "The app did not quit by itself; closing it."
        pkill -x FocusAssistant || true
        break
    fi
    state=$(camera_state)
    case "$state" in on*) DURING=$state ;; esac
    sleep 1
    WAITED=$((WAITED + 1))
done
sleep 1
AFTER=$(camera_state)

REPORT=build/selftest-last.txt
{
    echo "Self-test started $STARTED, requested $RUN_SECONDS s$APP_ARGS"
    echo "Camera before the run: $BEFORE"
    echo "Camera during the run: $DURING"
    echo "Camera after the app quit: $AFTER"
    /usr/bin/log show --start "$STARTED" --info --style compact \
        --predicate 'subsystem == "com.local.FocusAssistant" AND category == "shared"' 2>/dev/null \
        | sed -n 's/^[0-9-]* \([0-9:]*\)[.0-9]* .*\] \(.*\)$/\1 \2/p'
} > "$REPORT"
cat "$REPORT"
grep -q "SELFTEST result=ok" "$REPORT"
