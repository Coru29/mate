#!/bin/bash
# Measures Mate at rest, as the spec asks before every release: launches the installed app, waits 60 s, samples
# `top` once a second for 10 minutes with the panel closed, and fails if the average CPU is above 0.1 % or the
# memory (top's MEM, the physical footprint) goes above 30 MB.
#
# Usage: scripts/measure-idle.sh [--app <path/Mate.app>] [--pid <pid>] [--warmup <s>] [--samples <n>] [-- <app args>]
#   --app      the bundle to launch (default /Applications/Mate.app). The binary is started directly, so variables
#              such as MATE_DATA_DIR and MATE_DEFAULTS_SUITE reach it; only that process is stopped at the end.
#   --pid      measure a Mate that is already running instead (it is left running).
#   --warmup / --samples   default 60 s and 600 samples (the release check; shorter runs are only for trying it).
#   -- args    passed to the app, e.g. `-- --fake` for a run with the scripted provider and no network.
# Don't hover the notch while it runs: the numbers are for the panel closed.
set -euo pipefail
export LC_NUMERIC=C  # top prints "0.3"; awk must read it the same way in any locale
APP=/Applications/Mate.app
PID=""
WARMUP=60
SAMPLES=600
MAX_CPU=0.1
MAX_MB=30
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP=$2; shift 2 ;;
    --pid) PID=$2; shift 2 ;;
    --warmup) WARMUP=$2; shift 2 ;;
    --samples) SAMPLES=$2; shift 2 ;;
    --) shift; break ;;
    *) echo "usage: $0 [--app <Mate.app>] [--pid <pid>] [--warmup <s>] [--samples <n>] [-- <app args>]" >&2; exit 2 ;;
  esac
done

STARTED=""
cleanup() { if [ -n "$STARTED" ]; then kill "$STARTED" 2>/dev/null || true; fi; }
trap cleanup EXIT

if [ -z "$PID" ]; then
  BIN="$APP/Contents/MacOS/Mate"
  [ -x "$BIN" ] || { echo "No está $BIN (scripts/install.sh, o --app <ruta>)." >&2; exit 1; }
  # Two real instances would share the same data and keychain items; a --fake run is separate.
  if [ $# -eq 0 ] || [[ " $* " != *" --fake "* ]]; then
    if RUNNING=$(pgrep -x Mate); then
      echo "Mate ya está abierto (pid $RUNNING): medilo con --pid $RUNNING, cerralo antes, o usá -- --fake." >&2
      exit 1
    fi
  fi
  "$BIN" "$@" >/dev/null 2>&1 &
  STARTED=$!
  PID=$STARTED
  echo "Abierto $APP (pid $PID${*:+, $*}); esperando ${WARMUP} s…"
else
  kill -0 "$PID" 2>/dev/null || { echo "No hay un proceso $PID." >&2; exit 1; }
  echo "Midiendo el pid $PID; esperando ${WARMUP} s…"
fi
sleep "$WARMUP"
kill -0 "$PID" 2>/dev/null || { echo "Mate se cerró durante la espera." >&2; exit 1; }

echo "Tomando $SAMPLES muestras (una por segundo)…"
OUT=$(mktemp)
# One extra sample: top's first one has no CPU interval behind it and is dropped.
top -l $((SAMPLES + 1)) -s 1 -pid "$PID" -stats pid,cpu,mem > "$OUT"
kill -0 "$PID" 2>/dev/null || { rm -f "$OUT"; echo "Mate se cerró durante la medición." >&2; exit 1; }

STATUS=0
awk -v pid="$PID" -v maxcpu="$MAX_CPU" -v maxmb="$MAX_MB" '
  function mb(v,   n, u) {
    sub(/[+-]$/, "", v)
    u = substr(v, length(v)); n = substr(v, 1, length(v) - 1) + 0
    if (u == "B") return n / 1048576
    if (u == "K") return n / 1024
    if (u == "M") return n
    if (u == "G") return n * 1024
    return v / 1048576
  }
  $1 == pid {
    seen++
    if (seen == 1) next
    n++; cpu += $2; if ($2 > peak) peak = $2
    m = mb($3); mem += m; if (m > maxmem) maxmem = m
  }
  END {
    if (n == 0) { print "top no devolvió muestras del proceso."; exit 1 }
    avg = cpu / n
    printf "Muestras: %d\nCPU promedio: %.3f %% (pico %.1f %%; límite %.1f %%)\nMemoria: promedio %.1f MB, máximo %.1f MB (límite %d MB)\n", n, avg, peak, maxcpu, mem / n, maxmem, maxmb
    fail = 0
    if (avg > maxcpu) { print "FALLA: CPU en reposo por encima del límite."; fail = 1 }
    if (maxmem > maxmb) { print "FALLA: memoria por encima del límite."; fail = 1 }
    if (!fail) print "OK"
    exit fail
  }' "$OUT" || STATUS=$?
rm -f "$OUT"
exit $STATUS
