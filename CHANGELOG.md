# Changelog

## v0.2.0 — Control (2026-07-05)

- **Top Up button**: charge to 100% once (for a trip); the limit returns
  automatically after you unplug.
- **Discharge button**: drain down to your limit while plugged in, with live
  progress and a Stop button.
- **MagSafe LED control** (Settings): green when holding at the limit, amber
  while charging/discharging, or always off.
- **Notifications**: charge limit reached, Top Up / Discharge finished, heat
  protection, calibration done, failsafe. Toggle in Settings.
- Daemon now feeds recent events to the app (helper update required — one
  admin prompt on first launch).

## v0.1.1 (2026-07-05)

- Battery health now reads at most 100% by default (like Apple's Battery
  Health screen) — young batteries exceeding their factory rating confused
  people. The true uncapped value is available via Settings → "Show true
  battery health", and hovering the Health stat always shows the mAh math.
- UI-only releases no longer ask to update the helper; an admin prompt is
  only needed when the app↔helper protocol actually changes.

## v0.1.0 — Core (2026-07-05)

First release. Apple Silicon MacBooks (M1+), macOS 14+.

### Features
- **Charge Limit** (50–100%, any value): a root helper daemon toggles the SMC
  charging-inhibit key around your limit — enforced even when the app is
  closed, before login, and across daemon crashes/reboots.
- **Discharge to target** while plugged in (`ensoctl discharge <n>`, UI in v0.2).
- **Sleep correctness**: charging is proactively paused before sleep so the
  battery doesn't creep to 100% overnight; post-wake settling avoids acting
  on stale readings.
- **Menu bar app** (Liquid Glass on macOS 26): charge ring with limit tick,
  limit slider, battery health / cycles / temperature / power source stats.
- **Settings**: launch at login, quit behavior (keep limiting vs charge
  normally), stop-charging-before-sleep, keep-awake-until-limit, hardware
  battery percentage.
- **`ensoctl` CLI**: status, limit, topup, discharge, calibrate, cancel, plus
  read-only debug commands (`probe`, `dump-keys`, `battery`).
- **Safety**: hard failsafe (always allow charging ≤10%), every SMC write
  read-back-verified, unknown-firmware stand-down, restore-on-exit, clean
  uninstall restores stock behavior.

### Supported hardware strategies
- macOS 26 "Tahoe" firmware: `CHTE`/`CHIE` (verified on M4)
- Earlier Apple Silicon firmware: `CH0B`+`CH0C`/`CH0I` (per prior art; reports welcome)

### Known limitations
- Charging resumes to 100% when the Mac is fully powered off (hardware
  behavior, applies to every app of this kind).
- Discharge on an idle Mac is slow (~2–3%/hour) — that's physics.
- Disable macOS *Optimized Battery Charging* and the native charge limit to
  avoid the two systems fighting.
