#!/bin/bash
# Signs an app bundle with the "Rambla Local Signing" identity (shared with Rambla, so one certificate leaf covers both
# apps). This script never creates an identity and never falls back to ad-hoc signing.
# Usage: scripts/sign.sh build/Mate.app
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$1"
IDENTITY="Rambla Local Signing"
KC="${MATE_SIGNING_KEYCHAIN:-$HOME/Desktop/Proyectos/scroll/.signing/rambla-signing.keychain-db}"
# The keychain's password never lives in the repo. It comes from RAMBLA_SIGNING_PASSWORD or from this item of the
# login keychain. It is never printed.
PASS_ITEM="io.github.coru29.Rambla.signing"

if [ ! -f "$KC" ]; then
  echo "error: signing keychain not found at $KC (set MATE_SIGNING_KEYCHAIN)." >&2
  exit 1
fi
PASS="${RAMBLA_SIGNING_PASSWORD:-$(security find-generic-password -s "$PASS_ITEM" -w 2>/dev/null || true)}"
if [ -z "$PASS" ]; then
  echo "error: the signing keychain password is neither in RAMBLA_SIGNING_PASSWORD nor in the login keychain item $PASS_ITEM." >&2
  exit 1
fi
security unlock-keychain -p "$PASS" "$KC"

ORIGINAL=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [ -n "$line" ] && ORIGINAL+=("$line")
done < <(security list-keychains -d user)
restore() { security list-keychains -d user -s "${ORIGINAL[@]}"; }
trap restore EXIT
security list-keychains -d user -s "$KC" "${ORIGINAL[@]}"

codesign --force --options runtime --sign "$IDENTITY" --keychain "$KC" "$APP"
