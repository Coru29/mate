#!/bin/bash
# Measures Mate at rest, as the spec asks before every release: launches the installed app, waits 60 s, samples
# `top` once a second for 10 minutes with the panel closed, and fails if the average CPU is above 0.1 % or the
# memory (top's MEM, the physical footprint) goes above 30 MB.
#
# Usage: scripts/measure-idle.sh [--app <path/Mate.app>] [--pid <pid>] [--warmup <s>] [--samples <n>] [--notch]
#                                [--writer <s>] [--seed-index <dir>] [--max-cpu <percent>] [-- <app args>]
#   --app      the bundle to launch (default /Applications/Mate.app). The binary is started directly, so variables
#              such as MATE_DATA_DIR and MATE_DEFAULTS_SUITE reach it; only that process is stopped at the end.
#   --pid      measure a Mate that is already running instead (it is left running).
#   MATE_IDLE_RAW=<file>  also keeps top's raw samples there (to find what wakes it up when it fails).
#   --warmup / --samples   default 60 s and 600 samples (the release check; shorter runs are only for trying it).
#   -- args    passed to the app, e.g. `-- --fake` for a run with the scripted provider and no network; such a run
#              gets MATE_HEADLESS=1, so it never draws on the screen (and measures the engine without the notch).
# With `-- --fake` only:
#   --notch    runs the whole notch UI instead of headless, in a transparent window that lets every click through
#              (MATE_INVISIBLE=1): the pill's cost, with nothing on the screen.
#   --writer <s>  an agent at work: appends a Claude Code transcript entry every <s> seconds to a scratch log folder
#              the fake provider watches (MATE_FAKE_LOGS), from launch to the end. The CPU limit becomes 0.2 %.
#   --seed-index <dir>  starts from a copy of <dir>'s aggregates.json and cursors.json (e.g. the real
#              ~/Library/Application Support/Mate, which is only read) in a scratch data folder: a real-sized index.
#   --max-cpu  overrides the CPU limit.
# Don't hover the notch while it runs: the numbers are for the panel closed.
set -euo pipefail
export LC_NUMERIC=C  # top prints "0.3"; awk must read it the same way in any locale
APP=/Applications/Mate.app
PID=""
WARMUP=60
SAMPLES=600
MAX_CPU=""
MAX_MB=30
NOTCH=0
WRITER=""
SEED=""
USAGE="usage: $0 [--app <Mate.app>] [--pid <pid>] [--warmup <s>] [--samples <n>] [--notch] [--writer <s>] [--seed-index <dir>] [--max-cpu <percent>] [-- <app args>]"
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP=$2; shift 2 ;;
    --pid) PID=$2; shift 2 ;;
    --warmup) WARMUP=$2; shift 2 ;;
    --samples) SAMPLES=$2; shift 2 ;;
    --notch) NOTCH=1; shift ;;
    --writer) WRITER=$2; shift 2 ;;
    --seed-index) SEED=$2; shift 2 ;;
    --max-cpu) MAX_CPU=$2; shift 2 ;;
    --) shift; break ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
done
FAKE=0
if [ $# -gt 0 ] && [[ " $* " == *" --fake "* ]]; then FAKE=1; fi
if [ "$NOTCH" = 1 ] || [ -n "$WRITER" ] || [ -n "$SEED" ]; then
  if [ "$FAKE" = 0 ] || [ -n "$PID" ]; then echo "--notch, --writer y --seed-index son para una corrida nueva con -- --fake." >&2; exit 2; fi
fi
if [ -z "$MAX_CPU" ]; then if [ -n "$WRITER" ]; then MAX_CPU=0.2; else MAX_CPU=0.1; fi; fi

STARTED=""
WRITER_PID=""
SCRATCH=""
cleanup() {
  if [ -n "$WRITER_PID" ]; then kill "$WRITER_PID" 2>/dev/null || true; fi
  if [ -n "$STARTED" ]; then kill "$STARTED" 2>/dev/null || true; wait "$STARTED" 2>/dev/null || true; fi
  if [ -n "$SCRATCH" ]; then rm -rf "$SCRATCH"; fi
}
trap cleanup EXIT

# Appends one Claude Code exchange (a tool result and an assistant entry with usage) to $1 every $2 seconds.
write_logs() {
  local file=$1 every=$2 n=0 now filler
  filler=$(printf '%0400d' 0)
  while :; do
    n=$((n + 1))
    now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    printf '{"type":"user","timestamp":"%s","sessionId":"measure","message":{"role":"user","content":"tool result %d %s"}}\n' "$now" "$n" "$filler" >> "$file"
    printf '{"type":"assistant","timestamp":"%s","sessionId":"measure","cwd":"/tmp/measure","requestId":"req_%d","message":{"id":"msg_%d","model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}\n' "$now" "$n" "$n" >> "$file"
    sleep "$every"
  done
}

if [ -z "$PID" ]; then
  ABS=$(cd "$APP" 2>/dev/null && pwd) || { echo "No está la app $APP (scripts/install.sh, o --app <ruta>)." >&2; exit 1; }
  APP=$ABS
  BIN="$APP/Contents/MacOS/Mate"
  [ -x "$BIN" ] || { echo "No está $BIN (scripts/install.sh, o --app <ruta>)." >&2; exit 1; }
  # A second real copy of this same app would only hand off to the first and quit; measure that one instead.
  # Only this path counts: other copies (test builds, a --fake run) are separate.
  if [ "$FAKE" = 0 ]; then
    RUNNING=$(ps -axo pid=,comm= | awk -v exe="$BIN" '{pid=$1; $1=""; sub(/^ /, ""); if ($0 == exe) print pid}' | head -n 1)
    if [ -n "$RUNNING" ]; then
      echo "$APP ya está abierta (pid $RUNNING): medila con --pid $RUNNING, cerrala antes, o usá -- --fake." >&2
      exit 1
    fi
  fi
  # A --fake run is headless: nothing of it shows on the screen (no notch, no welcome guide, no window). With
  # --notch the notch runs in a transparent window that ignores the mouse, and the guide is skipped.
  if [ "$FAKE" = 1 ]; then
    if [ "$NOTCH" = 1 ]; then
      export MATE_INVISIBLE=1
      export MATE_DEFAULTS_SUITE=${MATE_DEFAULTS_SUITE:-io.github.coru29.Mate.measure}
    else
      export MATE_HEADLESS=1
    fi
  fi
  if [ -n "$WRITER" ] || [ -n "$SEED" ]; then
    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/mate-measure.XXXXXX")
    SCRATCH=$(cd "$SCRATCH" && pwd -P)
  fi
  if [ -n "$SEED" ]; then
    for f in aggregates.json cursors.json; do
      [ -f "$SEED/$f" ] || { echo "No está $SEED/$f." >&2; exit 1; }
    done
    mkdir -p "$SCRATCH/data"
    cp "$SEED/aggregates.json" "$SEED/cursors.json" "$SCRATCH/data/"
    export MATE_DATA_DIR="$SCRATCH/data"
  fi
  if [ -n "$WRITER" ]; then
    mkdir -p "$SCRATCH/logs/measure"
    export MATE_FAKE_LOGS="$SCRATCH/logs"
    write_logs "$SCRATCH/logs/measure/session.jsonl" "$WRITER" &
    WRITER_PID=$!
  fi
  "$BIN" "$@" >/dev/null 2>&1 &
  STARTED=$!
  PID=$STARTED
  MODE=""
  if [ $# -gt 0 ]; then MODE=", $*"; fi
  if [ "$NOTCH" = 1 ]; then MODE="$MODE, notch invisible"; fi
  if [ -n "$WRITER" ]; then MODE="$MODE, un log cada $WRITER s"; fi
  if [ -n "$SEED" ]; then MODE="$MODE, índice de $SEED"; fi
  echo "Abierto $APP (pid $PID$MODE); esperando ${WARMUP} s…"
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

if [ -n "${MATE_IDLE_RAW:-}" ]; then cp "$OUT" "$MATE_IDLE_RAW"; fi
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
