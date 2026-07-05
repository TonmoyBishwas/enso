#!/bin/bash
# Builds Enso.app and packages it for a GitHub release:
# dist/Enso.zip + dist/Enso.zip.sha256 + dist/RELEASE_NOTES.md
set -euo pipefail

cd "$(dirname "$0")/.."

./Scripts/make-app.sh dist

echo "Zipping (ditto preserves signatures and xattrs)..."
rm -f dist/Enso.zip dist/Enso.zip.sha256
ditto -c -k --keepParent dist/Enso.app dist/Enso.zip
(cd dist && shasum -a 256 Enso.zip > Enso.zip.sha256)

./Scripts/make-dmg.sh

cat > dist/RELEASE_NOTES.md <<'EOF'
## Easiest install (recommended)

Paste this in Terminal — it downloads, installs, and opens Enso with no
security warnings:

```
curl -fsSL https://raw.githubusercontent.com/TonmoyBishwas/enso/main/install.sh | bash
```

## Manual install

Download `Enso.dmg`, open it, and drag **Enso** into **Applications**.
Because Enso is free open-source software without Apple's paid notarization,
macOS blocks the first launch of a *downloaded* copy — open **System
Settings → Privacy & Security** and click **Open Anyway**, or run:

```
xattr -dr com.apple.quarantine /Applications/Enso.app
```

## After installing (both ways)

1. Click Enso in the menu bar and press **Install Helper** — a one-time
   admin-password step that installs the daemon that controls charging.
2. Turn off **System Settings → Battery → Optimized Battery Charging** so
   macOS doesn't fight Enso.

## Uninstalling

Use **Settings → Uninstall Helper…** inside Enso, then trash the app.

## Checksums

`shasum -a 256 -c Enso.zip.sha256`
EOF

echo "Release artifacts ready in dist/"
ls -la dist/
