#!/bin/bash
# Builds dist/Enso.dmg from dist/Enso.app — the classic drag-to-Applications
# window, using only hdiutil (no external dependencies).
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/Enso.app"
DMG="dist/Enso.dmg"
[ -d "$APP" ] || { echo "run Scripts/make-app.sh first" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/Enso.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'EOF'
Installing Enso
===============

1. Drag Enso into the Applications folder alongside it.

2. Because Enso is free open-source software (not notarized by Apple),
   macOS will block the first launch. Fix it either way:

   • Open System Settings → Privacy & Security, scroll down, and click
     "Open Anyway" next to the Enso message.

   • Or paste this in Terminal:
     xattr -dr com.apple.quarantine /Applications/Enso.app

   Tip: installing with the one-line Terminal command from the project
   README skips this block entirely.

3. Launch Enso from the menu bar, click "Install Helper" (one-time,
   asks for your password), and turn OFF System Settings → Battery →
   Optimized Battery Charging.

https://github.com/TonmoyBishwas/enso
EOF

rm -f "$DMG"
hdiutil create -volname "Enso" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
echo "Done: $DMG"
