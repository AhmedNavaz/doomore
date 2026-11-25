#!/bin/sh
# Rough resource cost of the app, measured with `top` (no sudo needed).
# Runs three matched conditions one after another, each for the same time:
#   1. no app          whole-system CPU only, as the background level
#   2. capture-only    camera frames delivered, no analysis
#   3. signals         camera plus face, hands, body and classifier analysis
# Both app conditions hide the live preview. The camera light is on during 2 and 3.
#
# Usage: scripts/measure.sh [seconds per condition] [--no-build]   (default 120)
#
# Reports, per app condition after a warm-up of WARMUP seconds: CPU mean / p95 / peak
# (100% = one CPU core, Activity Monitor's convention), memory footprint first / last / peak,
# and macOS's "energy impact" score from top's POWER column. Energy impact is a relative
# score, not watts; watts need `sudo powermetrics`, which this script does not use.
# Results go to build/measure-last.txt.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

SECONDS_EACH=120
BUILD_ARG=""
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD_ARG="--no-build" ;;
        ''|*[!0-9]*) echo "usage: scripts/measure.sh [seconds per condition] [--no-build]" >&2; exit 2 ;;
        *) SECONDS_EACH=$arg ;;
    esac
done
WARMUP=15
INTERVAL=2
OUT=build/measure-last.txt
mkdir -p build

# Summarises top samples: lines of "cpu mem power" after the warm-up.
summarise() {
    awk -v warm="$((WARMUP / INTERVAL))" '
        function mb(v,    u, x) { sub(/[+-]$/, "", v); u = substr(v, length(v)); x = v + 0
            if (u == "K") return x / 1024; if (u == "G") return x * 1024; if (u == "B") return x / 1048576; return x }
        $1 !~ /^[0-9.]+$/ { next }
        { i++; if (i <= warm) next
          c[++n] = $1 + 0; m = mb($2); if (n == 1) first = m; last = m; if (m > peak) peak = m
          p += $3; s += $1 }
        END {
            if (n == 0) { print "no samples after warm-up"; exit }
            for (a = 1; a <= n; a++) for (b = a + 1; b <= n; b++) if (c[b] < c[a]) { t = c[a]; c[a] = c[b]; c[b] = t }
            k = int(0.95 * n + 0.999); if (k < 1) k = 1; if (k > n) k = n
            printf "samples=%d cpu_mean=%.1f%% cpu_p95=%.1f%% cpu_peak=%.1f%% mem_first=%.0fMB mem_last=%.0fMB mem_peak=%.0fMB energy_impact_mean=%.1f\n",
                n, s / n, c[k], c[n], first, last, peak, p / n }'
}

{
    echo "Measurement started $(date '+%Y-%m-%d %H:%M:%S'), $SECONDS_EACH s per condition, warm-up $WARMUP s, sample every $INTERVAL s"
    echo "Machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores; power source: $(pmset -g batt | head -1 | sed "s/.*'\(.*\)'.*/\1/")"
    echo "Thermal: $(pmset -g therm 2>/dev/null | grep -i 'CPU_Speed_Limit\|warning' | tr '\n' ' ' || true)"
} > "$OUT"

if pgrep -x FocusAssistant > /dev/null; then pkill -x FocusAssistant || true; sleep 1; fi

# 1. No app: whole-system CPU from top's header (user + sys, share of all cores).
echo "Condition 1/3: no app, $SECONDS_EACH s"
SAMPLES=$((SECONDS_EACH / INTERVAL + 1))
top -l "$SAMPLES" -s "$INTERVAL" -n 0 | awk -v warm="$((WARMUP / INTERVAL))" '
    /^CPU usage/ { i++; if (i <= warm) next; gsub("%", ""); u += $3; s += $5; n++ }
    END { if (n) printf "no-app system_cpu_mean=%.1f%% of all cores (user %.1f, sys %.1f), samples=%d\n", (u + s) / n, u / n, s / n, n }' >> "$OUT"

run_condition() {
    name=$1; shift
    echo "Condition: $name, $SECONDS_EACH s (camera on)"
    # shellcheck disable=SC2086
    scripts/selftest.sh "$SECONDS_EACH" --no-preview "$@" $BUILD_ARG > "build/measure-$name-selftest.txt" 2>&1 &
    runner=$!
    pid=""
    for _ in $(seq 1 60); do
        pid=$(pgrep -x FocusAssistant || true)
        [ -n "$pid" ] && break
        sleep 1
    done
    if [ -z "$pid" ]; then echo "$name: app did not start" >> "$OUT"; wait "$runner" || true; return; fi
    top -l 0 -s "$INTERVAL" -pid "$pid" -stats cpu,mem,power 2>/dev/null \
        | awk '/^%CPU/ { getline; print; fflush() }' > "build/measure-$name-top.txt" &
    sampler=$!
    wait "$runner" || true
    kill "$sampler" 2>/dev/null || true
    printf '%s ' "$name" >> "$OUT"
    summarise < "build/measure-$name-top.txt" >> "$OUT"
    grep -E "SUMMARY end=|SELFTEST result" "build/measure-$name-selftest.txt" | sed "s/^/$name: /" >> "$OUT" || true
    BUILD_ARG="--no-build" # Build at most once.
}

run_condition capture-only --capture-only
run_condition signals

cat "$OUT"
