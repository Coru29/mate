#!/bin/bash
# Builds the app and packages it as build/Mate.dmg (app + Applications alias).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh
VERSION=${MATE_VERSION:-$(tr -d '[:space:]' < VERSION)}
STAGE=$(mktemp -d)
cp -R build/Mate.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Stable name so https://github.com/Coru29/mate/releases/latest/download/Mate.dmg always works.
DMG="build/Mate.dmg"
rm -f "$DMG"
hdiutil create -volname "Mate" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "$DMG"
