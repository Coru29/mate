#!/bin/bash
# Builds the app and packages it as build/Mate.dmg (app + Applications alias).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh
VERSION=${MATE_VERSION:-$(tr -d '[:space:]' < VERSION)}
STAGE=$(mktemp -d)
cp -R build/Mate.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Stable asset name: every release carries Mate.dmg (the updater and the release notes link to it). While all
# releases are 0.x pre-releases, GitHub's /releases/latest/download/ link does not resolve; link /releases instead.
DMG="build/Mate.dmg"
rm -f "$DMG"
hdiutil create -volname "Mate" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "$DMG"
