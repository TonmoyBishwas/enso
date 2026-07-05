# Testing Enso

## What CI covers (no hardware)

- `EnsoEngine` scenario tests: charge-to-limit, unplug/replug, sleep/wake around the limit, heat spike mid-calibration, task cancellation, failsafe at 10%.
- Property tests against a simulated battery (±0.5%/tick): steady-state SoC never exceeds limit+2; action is never `inhibit` at SoC ≤ 10; discharge never goes below the 15% floor. Simulated clock exercises hysteresis timers.
- `SMCParamStruct` packing, FourCC encoding, capability-probe decision table over fake key inventories.
- Config validation/clamping, DTO round-trips, schedule "next opportunity" math.

Run: `swift test --package-path Packages/EnsoCore`

## Manual hardware protocol (maintainers, Apple Silicon + charger)

Guard rails are in code (limit clamp 50–100, discharge floor 15%, failsafe ≤10%, restore-on-SIGTERM, allow-on-no-adapter) — but never run tests below 20% SoC anyway.

1. **Snapshot:** `ensoctl debug dump-keys > keys-before.txt` — the restore reference.
2. **Dry-run soak:** run the daemon with `--dry-run` (DryRunSMC) for a day; diff intended writes against expectations.
3. **First write** (SoC 60–80%, plugged in): inhibit → within 30s `pmset -g batt` shows not charging → restore → charging resumes. The test script traps errors/Ctrl-C and auto-restores.
4. **Maintain:** limit 70 near 65%; verify charge stops at 70 and holds ±1% for an hour.
5. **Sleep:** limit 70 at 70%, `sudo pmset sleepnow`, overnight on AC, lid closed. Morning SoC must be ≤ 72%.
6. **Discharge:** 80 → 75 on AC; Amperage goes negative; auto-stops at target; `ensoctl cancel` aborts.
7. **Chaos:** `sudo kill -9` the daemon mid-inhibit → launchd respawn + correct state within 30s. Reboot while limited → limit reapplied within one tick.
8. **Uninstall:** full uninstall → `ensoctl debug dump-keys` (before removal) matches the snapshot; charging to 100% works.
