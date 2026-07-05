# Enso Architecture

Enso is three executables plus one Swift package:

```
┌───────────────────────────┐        ┌──────────────────────────────┐
│ Enso.app (user, no root)  │  XPC   │ com.enso.daemon (root)       │
│  SwiftUI MenuBarExtra     │◄──────►│  MaintainLoop (10s tick)     │
│  Settings, HelperInstaller│  mach  │  ChargingStateMachine (pure) │
│  Battery stats (read-only)│service │  PowerEvents (sleep/wake)    │
└───────────────────────────┘        │  SMCConnection (writes)      │
┌───────────────────────────┐        └──────────────────────────────┘
│ ensoctl (CLI, same XPC)   │
└───────────────────────────┘
```

## Packages/EnsoCore

| Module | Responsibility | Root? |
|---|---|---|
| `EnsoShared` | XPC protocol, `EnsoConfig`, DTOs, `DAEMON_PROTOCOL_VERSION` | – |
| `EnsoEngine` | `ChargingStateMachine` — a pure function `step(input, &memory) -> output`. No IOKit, no clocks, no timers. Fully unit-tested. | – |
| `EnsoSMC` | AppleSMC IOKit user client: typed reads/writes, capability probing (`CHTE/CHIE` vs `CH0B/CH0C/CH0I`), `MockSMC` + `DryRunSMC` test doubles | writes: root |
| `EnsoBattery` | `AppleSmartBattery` IORegistry snapshots + IOPowerSources change stream | no |

The root `Package.swift` builds three executables from this package: `Enso`
(SwiftUI menu bar app, `Apps/Enso`), `ensod` (root daemon, `Daemon/EnsoDaemon`),
and `ensoctl` (CLI, `CLI/ensoctl`). `Scripts/make-app.sh` assembles them into
an ad-hoc-signed `Enso.app` with the daemon and install scripts as bundle
resources.

**Force-discharge caveat (learned on hardware):** discharging works by
disabling the adapter in firmware (`CHIE = 0x8`), which makes IOKit report the
adapter as disconnected on the next tick. The engine therefore skips the
"cancel tasks on unplug" rule while its own last action was `forceDischarge`.

## Design rules

1. **The daemon owns every charging decision.** The app is UI + config only. If the app crashes, the limit keeps being enforced. On graceful quit the app sends `appWillQuit`; the daemon keeps maintaining or resets to 100%, per user setting.
2. **The engine is pure.** All inputs (battery %, temperature, wall-clock, sleep phase, config) are injected. Output is `(action, sleepBlock, led, events)`. This makes the safety-critical logic exhaustively testable in CI without hardware.
3. **Engine priority order, first match wins:**
   - P0 failsafe (SoC ≤ 10% / no working key / SMC error streak → allow, cancel tasks)
   - P1 no adapter → allow
   - P2 pre-sleep inhibit / post-wake settle
   - P3 heat protection (inhibit; resume after temp < threshold−2°C AND 5 min)
   - P4 calibration sub-machine
   - P5 top up
   - P6 discharge task
   - P7 maintain with hysteresis (sailing lower bound, or limit−1)
4. **Every SMC write is verified by read-back.** Three consecutive failures → re-probe capabilities → if no strategy works, failsafe + "unsupported firmware" status.
5. **Sleep correctness** (the classic "charged to 100% overnight" bug): on `kIOMessageSystemWillSleep` the daemon proactively inhibits charging if limit < 100 and suppresses the maintain loop for 60s; on wake it waits 30s before acting.

## Privilege model

No paid Apple Developer account → `SMAppService.daemon` is unavailable (rejects ad-hoc signing). Enso uses a classic LaunchDaemon:

- App bundles the daemon binary; one admin prompt runs `Scripts/install-daemon.sh` which copies it to `/Library/PrivilegedHelperTools/com.enso.daemon`, renders the plist into `/Library/LaunchDaemons/`, and `launchctl bootstrap`s it.
- The installer also generates a random shared secret stored at `/Library/Application Support/com.enso.daemon/secret` (root-only, 0600) and `~/Library/Application Support/Enso/secret` (user-only, 0600). XPC clients must present it in `handshake()` before any other call is honored.
- The XPC protocol is deliberately minimal: `getStatus`, `applyConfig` (daemon re-validates and clamps 50–100), `runCommand` (fixed enum), `prepareUninstall`. There is **no** raw SMC access over XPC.

**Threat model, honestly:** without Developer ID signing we cannot pin the client's code signature. The secret protects against other local users and unprivileged processes, not against malware running as the same user. Worst case for a bypass is "change the charge limit within 50–100%" — annoying, not dangerous. If a Developer ID cert arrives later, `setCodeSigningRequirement` pinning and `SMAppService.daemon` slot into `HelperInstaller` without touching the rest.

## Daemon lifecycle

- **Upgrade:** both binaries embed `DAEMON_PROTOCOL_VERSION`; handshake mismatch → app shows "Helper update required" → same installer script (`bootout` first, secret preserved). Releases that don't touch the daemon skip the admin prompt.
- **Crash:** `KeepAlive` → launchd respawns; daemon reloads config + engine memory and reconciles SMC state within one tick.
- **macOS update / firmware change:** capabilities re-probed on every daemon start and every wake (the Tahoe `CHTE` switch is the precedent).
- **Uninstall:** XPC `prepareUninstall` (limit 100, keys restored, LED → system) → admin script removes binary, plist, support dir.
