#!/bin/bash
# Installs (or upgrades) the Enso privileged helper daemon.
# Must run as root. Invoked by the Enso app via an admin prompt, or manually:
#   sudo ./install-daemon.sh <path-to-ensod-binary> <path-to-plist-template> <console-user>
set -euo pipefail

DAEMON_BIN="${1:?usage: install-daemon.sh <ensod-binary> <plist-template> <console-user>}"
PLIST_TEMPLATE="${2:?missing plist template}"
CONSOLE_USER="${3:?missing console user}"

LABEL="com.enso.daemon"
HELPER_DIR="/Library/PrivilegedHelperTools"
HELPER_PATH="$HELPER_DIR/$LABEL"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT_DIR="/Library/Application Support/$LABEL"
ROOT_SECRET="$SUPPORT_DIR/secret"
USER_HOME=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')
USER_SECRET_DIR="$USER_HOME/Library/Application Support/Enso"
USER_SECRET="$USER_SECRET_DIR/secret"

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -f "$DAEMON_BIN" ] || { echo "daemon binary not found: $DAEMON_BIN" >&2; exit 1; }

echo "Stopping any existing daemon..."
launchctl bootout system "$PLIST_PATH" 2>/dev/null || true

echo "Installing helper binary..."
mkdir -p "$HELPER_DIR" "$SUPPORT_DIR"
install -o root -g wheel -m 755 "$DAEMON_BIN" "$HELPER_PATH"

echo "Installing LaunchDaemon plist..."
install -o root -g wheel -m 644 "$PLIST_TEMPLATE" "$PLIST_PATH"

# Shared secret: generate once, keep across upgrades.
if [ ! -f "$ROOT_SECRET" ]; then
  echo "Generating client secret..."
  uuidgen | tr -d '\n' > "$ROOT_SECRET"
fi
chown root:wheel "$ROOT_SECRET"
chmod 600 "$ROOT_SECRET"

# User-side copy so the (unprivileged) app and CLI can authenticate.
mkdir -p "$USER_SECRET_DIR"
cp "$ROOT_SECRET" "$USER_SECRET"
chown "$CONSOLE_USER" "$USER_SECRET"
chmod 600 "$USER_SECRET"

echo "Starting daemon..."
launchctl bootstrap system "$PLIST_PATH"
launchctl kickstart -k "system/$LABEL" 2>/dev/null || true

echo "Enso helper installed."
