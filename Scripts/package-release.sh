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

cat > dist/RELEASE_NOTES.md <<'EOF'
## Installing

1. Download `Enso.zip`, unzip, and drag **Enso.app** into `/Applications`.
2. Enso is a free open-source app without Apple's paid notarization, so
   macOS blocks the first launch. Remove the quarantine flag:

   ```
   xattr -dr com.apple.quarantine /Applications/Enso.app
   ```

   (or open **System Settings → Privacy & Security** and click **Open Anyway**.)
3. Launch Enso from the menu bar and click **Install Helper** — this one-time
   step (admin password) installs the root daemon that controls charging.
4. Turn off **System Settings → Battery → Optimized Battery Charging** so
   macOS doesn't fight Enso.

## Uninstalling

Use **Settings → Uninstall Helper…** inside Enso, then trash the app.

## Checksums

`shasum -a 256 -c Enso.zip.sha256`
EOF

echo "Release artifacts ready in dist/"
ls -la dist/
