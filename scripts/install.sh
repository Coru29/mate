#!/bin/bash
# Builds, replaces /Applications/Mate.app and relaunches it. Extra arguments are passed to the app.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh
if pgrep -x Mate >/dev/null; then
  osascript -e 'tell application id "io.github.coru29.Mate" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do pgrep -x Mate >/dev/null || break; sleep 0.1; done
  pkill -x Mate 2>/dev/null || true
fi
rm -rf /Applications/Mate.app
ditto build/Mate.app /Applications/Mate.app
if [ $# -gt 0 ]; then open -a /Applications/Mate.app --args "$@"; else open -a /Applications/Mate.app; fi
echo "Installed /Applications/Mate.app"
