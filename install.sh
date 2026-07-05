#!/bin/bash
# Enso installer — downloads the latest release and installs it cleanly.
# Usage:  curl -fsSL https://raw.githubusercontent.com/TonmoyBishwas/enso/main/install.sh | bash
#
# Why this exists: Enso is free and open source, without Apple's paid
# notarization. Browser downloads get quarantined and blocked by Gatekeeper;
# curl downloads don't, so this script installs an app that opens normally.
set -euo pipefail

REPO="TonmoyBishwas/enso"
APP_DIR="/Applications"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

# Apple Silicon only.
if [ "$(uname -m)" != "arm64" ]; then
  echo "Enso supports Apple Silicon Macs only (M1 or newer)." >&2
  exit 1
fi

bold "Finding the latest Enso release..."
ZIP_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*Enso\.zip"' \
  | sed 's/.*"\(https[^"]*\)"/\1/')
[ -n "$ZIP_URL" ] || { echo "Could not find a release download. Check https://github.com/$REPO/releases" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

bold "Downloading $ZIP_URL ..."
curl -fL --progress-bar "$ZIP_URL" -o "$TMP/Enso.zip"

bold "Installing to $APP_DIR/Enso.app ..."
ditto -x -k "$TMP/Enso.zip" "$TMP"

# Quit a running Enso before replacing it.
osascript -e 'tell application "Enso" to quit' >/dev/null 2>&1 || true
sleep 1

rm -rf "$APP_DIR/Enso.app"
ditto "$TMP/Enso.app" "$APP_DIR/Enso.app"
# curl downloads aren't quarantined, but clear any stray flag just in case.
xattr -dr com.apple.quarantine "$APP_DIR/Enso.app" 2>/dev/null || true

bold "Launching Enso..."
open "$APP_DIR/Enso.app"

echo
bold "Enso is installed! Two one-time steps remain in the app:"
echo "  1. Click the Enso icon in the menu bar and press “Install Helper”"
echo "     (asks for your password — that's the part that controls charging)."
echo "  2. Turn OFF System Settings → Battery → Optimized Battery Charging."
