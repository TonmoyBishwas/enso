#!/bin/bash
# Assembles Enso.app from the SPM release build.
# Usage: ./Scripts/make-app.sh [output-dir]   (default: dist/)
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
OUT="${1:-dist}"
VERSION=$(grep 'public let ENSO_VERSION' Packages/EnsoCore/Sources/EnsoShared/EnsoConfig.swift | sed 's/.*"\(.*\)".*/\1/')
APP="$OUT/Enso.app"

echo "Building release binaries (v$VERSION)..."
swift build -c release

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

sed "s/__VERSION__/$VERSION/g" Scripts/Info.plist.template > "$APP/Contents/Info.plist"

cp .build/release/Enso   "$APP/Contents/MacOS/Enso"
cp .build/release/ensod  "$APP/Contents/Resources/ensod"
cp .build/release/ensoctl "$APP/Contents/Resources/ensoctl"
cp Scripts/install-daemon.sh Scripts/uninstall.sh Scripts/com.enso.daemon.plist.template \
   "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/install-daemon.sh" "$APP/Contents/Resources/uninstall.sh"

if [ -f "Assets/AppIcon.icns" ]; then
  cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "Ad-hoc signing..."
codesign --force -s - "$APP/Contents/Resources/ensod"
codesign --force -s - "$APP/Contents/Resources/ensoctl"
codesign --force -s - "$APP"

echo "Done: $APP"
