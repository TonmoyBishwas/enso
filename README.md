# Enso

**Free & open-source battery charge limiter for Apple Silicon MacBooks.**

Enso keeps your MacBook's battery healthy by limiting how far it charges — like [AlDente](https://apphousekitchen.com), but every feature is free and the code is open. Lithium-ion batteries age fastest when held at 100%; keeping the charge around 80% dramatically slows capacity loss.

> ⚠️ **Status: early development.** v0.1 (core charge limiting) is being built in the open. Watch/star the repo for releases.

## Features (roadmap)

- ✅ = shipped, 🔜 = planned
- ✅ **Charge Limit** — hold the battery at any level from 50–100% (not just Apple's 5% steps)
- ✅ **Top Up** — temporarily charge to 100% for a trip, auto-revert after unplugging
- ✅ **Discharge** — drain to your limit while plugged in (automatic mode planned)
- ✅ **MagSafe LED control** — green at limit, amber while charging
- ✅ **Notifications** — limit reached, discharge done, heat protection
- ✅ **Hardware battery %** — read the true BMS value, not the smoothed one
- ✅ **A real CLI** (`ensoctl`) — something AlDente doesn't have
- ✅ Battery stats (health, cycles, temperature), launch at login
- 🔜 **Sailing Mode** — let the charge drift in a range (e.g. 75–80%) instead of micro-charging at one number
- 🔜 **Heat Protection** — pause charging when the battery runs hot
- 🔜 **Calibration Mode** — scheduled full cycles to keep the battery gauge accurate
- 🔜 **Schedules** — automate limits, calibration, top-ups
- 🔜 **Stats history & Power Flow**, Shortcuts support, menu bar customization

## The CLI

```
ensoctl status                 # daemon state, strategy, current action
ensoctl limit 80               # set the charge limit
ensoctl topup                  # charge to 100% once
ensoctl discharge 60           # drain to 60% while on AC
ensoctl cancel                 # stop the active task
ensoctl debug probe            # which SMC keys your Mac speaks
ensoctl debug battery          # full battery snapshot as JSON
```

`ensoctl` ships inside the app bundle: `ln -s /Applications/Enso.app/Contents/Resources/ensoctl /usr/local/bin/ensoctl`

**Requirements:** Apple Silicon MacBook (M1 or newer), macOS 14+. Intel Macs are not supported.

## How it works

Apple Silicon Macs have no user-facing "charge to N%" register, so Enso ships a tiny root helper (a `launchd` daemon) that watches the battery and toggles the SMC charging-inhibit key around your limit — the same proven approach used by [batt](https://github.com/charlie0129/batt) and BatFi. The app itself is a lightweight SwiftUI menu bar app; all charging decisions run in the helper, so your limit is enforced even when the app is closed or before you log in.

Safety is designed in, not bolted on:
- Hard failsafe: charging is always allowed at ≤10% battery, no matter what.
- Every SMC write is read back and verified; unknown firmware → Enso stands down.
- Unplugged Macs never hold a stale "don't charge" state.
- Uninstalling restores everything to stock (limit 100%, LED to system control).

## Installing

**Easiest — one line in Terminal** (no security warnings, because Terminal
downloads skip macOS quarantine):

```bash
curl -fsSL https://raw.githubusercontent.com/TonmoyBishwas/enso/main/install.sh | bash
```

**Or manually:** download `Enso.dmg` from [Releases](../../releases) and drag
**Enso** into **Applications**. Enso is free open-source software without
Apple's $99/yr notarization, so macOS blocks the first launch of a browser
download — open **System Settings → Privacy & Security** and click **"Open
Anyway"**, or run `xattr -dr com.apple.quarantine /Applications/Enso.app`.

**After either install (one time):**
1. Click Enso in the menu bar and press **Install Helper** (asks for your admin password — that's the root daemon that does the actual charge limiting).
2. **Turn off** System Settings → Battery → *Optimized Battery Charging* (and Apple's own charge limit if set), so macOS doesn't fight Enso.

## Uninstalling

Use **Settings → Uninstall Helper** inside Enso (restores your battery to stock behavior), then trash the app. If you already deleted the app, run `Scripts/uninstall.sh` from this repo with `sudo`.

## Building from source

```bash
git clone https://github.com/TonmoyBishwas/enso.git && cd enso
./Scripts/make-app.sh          # builds dist/Enso.app (needs Xcode 26+)
swift test --package-path Packages/EnsoCore   # run the test suite
```

Or open the folder in Xcode (`xed .`) and run the `Enso` scheme. The core logic lives in the `Packages/EnsoCore` Swift package; the app, root daemon (`ensod`), and CLI (`ensoctl`) are SPM executable targets assembled into an app bundle by `Scripts/make-app.sh`.

## Documentation

- [docs/CODEBASE.md](docs/CODEBASE.md) — the in-depth guided tour: every module, the charging engine's rule ladder, the privilege model, hardware gotchas, and how to add a feature.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the one-page overview.
- [docs/SMC-KEYS.md](docs/SMC-KEYS.md) — the SMC key registry (with hardware-verification status).
- [docs/TESTING.md](docs/TESTING.md) — CI coverage and the manual hardware protocol.
- [CLAUDE.md](CLAUDE.md) — guardrails and known traps for AI coding agents (useful reading for humans too).

## License

MIT — see [LICENSE](LICENSE).
