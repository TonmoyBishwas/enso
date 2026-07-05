#!/bin/bash
# Fully removes the Enso helper daemon and restores stock charging behavior.
# Run with: sudo ./uninstall.sh
# (Prefer "Uninstall Helper" inside the Enso app; this script covers the case
# where the app was already deleted.)
set -uo pipefail

LABEL="com.enso.daemon"
HELPER_PATH="/Library/PrivilegedHelperTools/$LABEL"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT_DIR="/Library/Application Support/$LABEL"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (sudo)" >&2; exit 1; }

# Ask the daemon to restore SMC keys before we kill it (best-effort; its
# SIGTERM handler restores as well).
echo "Stopping daemon (restores charging on exit)..."
launchctl bootout system "$PLIST_PATH" 2>/dev/null || true
sleep 1

echo "Removing files..."
rm -f "$HELPER_PATH" "$PLIST_PATH"
rm -rf "$SUPPORT_DIR"

echo "Enso helper removed. Battery charging is back to stock macOS behavior."
echo "You may also delete ~/Library/Application Support/Enso and the app itself."
