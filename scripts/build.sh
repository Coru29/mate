#!/bin/bash
# Builds build/Mate.app (release, arm64) and signs it.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${MATE_VERSION:-$(tr -d '[:space:]' < VERSION)}
BUILD=$(date +%Y%m%d%H%M)
swift build -c release --product Mate
BIN="$(swift build -c release --show-bin-path)/Mate"
APP=build/Mate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mate"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Packaging/Info.plist > "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Spanish is the source language (the keys); English comes from en.lproj and is also the fallback for other languages.
cp -R Packaging/en.lproj Packaging/es.lproj "$APP/Contents/Resources/"
scripts/sign.sh "$APP"
echo "$APP ($VERSION, build $BUILD)"
