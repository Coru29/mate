#!/bin/bash
# Builds, replaces /Applications/Mate.app and relaunches it. Extra arguments are passed to the app.
# Only the copy running from /Applications is quit (by its PID): test instances elsewhere keep running.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh
INSTALLED=/Applications/Mate.app
EXE="$INSTALLED/Contents/MacOS/Mate"
installed_pids() { ps -axo pid=,comm= | awk -v exe="$EXE" '{pid=$1; $1=""; sub(/^ /, ""); if ($0 == exe) print pid}'; }
PIDS=$(installed_pids)
if [ -n "$PIDS" ]; then
  # SIGTERM makes Mate quit normally (it saves its state); then SIGKILL for the same PIDs if they are still there.
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  for _ in $(seq 1 50); do
    ALIVE=""
    for p in $PIDS; do kill -0 "$p" 2>/dev/null && ALIVE="$ALIVE $p"; done
    [ -z "$ALIVE" ] && break
    sleep 0.1
  done
  for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done
fi
rm -rf "$INSTALLED"
ditto build/Mate.app "$INSTALLED"
if [ $# -gt 0 ]; then open -a "$INSTALLED" --args "$@"; else open -a "$INSTALLED"; fi
echo "Installed $INSTALLED"
