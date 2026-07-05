# Enso — Free & Open-Source AlDente Alternative (Apple Silicon)

> **Historical document.** This is the original pre-implementation design
> spec, kept for the research notes and rationale. Details drifted during
> implementation (timings, engine rule order, file names) — where this file
> and the code disagree, the code wins. For current documentation see
> [CODEBASE.md](CODEBASE.md) and [ARCHITECTURE.md](ARCHITECTURE.md).

## Context

The user wants a free, open-source macOS battery charge limiter equivalent to AlDente Pro (AppHouseKitchen). AlDente locks most features (calibration, heat protection, scheduling, etc.) behind a paid tier. Goal: a community-usable app that covers ~all of AlDente's functionality, free.

**Decisions (confirmed with user):**
- Name: **Enso** (matches repo `TonmoyBishwas/enso`)
- Target: Apple Silicon only (M1–M4+), macOS 26 Tahoe-era (machine runs macOS 26.5.1, Xcode 26.5). No Intel support.
- UI: Native SwiftUI menu bar app with Apple's Liquid Glass design language.
- Distribution: No paid Apple Developer account → ad-hoc signed builds on GitHub Releases with right-click-to-open/xattr install instructions; structure so Developer ID signing can be added later.
- Release strategy: staged — v0.1 core charge limiting + menu bar UI shipped early, then incremental releases (sailing, heat protection, calibration, scheduling, …) using GitHub Releases.
- Push regularly to `https://github.com/TonmoyBishwas/enso.git`, commit author email ttomoy46@gmail.com.

## Research (in progress)

Three Opus research agents dispatched:
1. AlDente Free/Pro exhaustive feature inventory + known quirks
2. SMC mechanics on Apple Silicon (CHWA/CH0B/CH0C/CHTE, MagSafe LED, sleep/wake bugs) + open-source prior art (batt, BatFi, Battery Toolkit, actuallymentor/battery, bclm)
3. Liquid Glass adoption in SwiftUI, MenuBarExtra best practices, SMAppService.daemon privileged helper, unsigned FOSS distribution

Findings to be folded in below.

### Research 1 — AlDente feature inventory (complete)

**Free tier:** Charge Limiter (slider/numeric, pauses charging at limit, runs off adapter), manual Discharge (simulated unplug, drain to target), live status menu-bar icons, battery health stats + cycles graph.

**Pro tier (our target feature set, all free in Enso):**
- Automatic Discharge (auto-drain to limit whenever above it while plugged)
- Discharge in Clamshell Mode (requires disabling sleep during discharge)
- Sailing Mode (upper/lower range, e.g. 75–80%, avoids micro-charging wobble; dashed range on slider)
- Top Up (temporary 100% for one cycle, auto-revert after unplug; pauses Sailing)
- Heat Protection (pause charging above temp threshold, ~35°C default, 5-min hysteresis cooldown; auto-off during calibration)
- Calibration Mode (100% → drain to ~10-15% → 100% → hold 1h → back to limit; schedulable)
- Schedule/Automation (actions: set limit, calibrate, top up, pause charging, discharge-to; repeats daily/weekdays/weekly/biweekly/monthly; "start at next opportunity" on wake)
- MagSafe LED control (green=limit reached, orange=charging; MagSafe 3: blinking orange during discharge, "Always Off")
- Hardware Battery Percentage (true BMS % vs macOS-smoothed, differ 2–7%)
- Stop Charging when App Closed (helper persists limit)
- Stop Charging when Sleeping (hold pre-sleep level overnight)
- Disable Sleep until Charge Limit (prevent sleep while still charging to target)
- Power Flow (Sankey diagram: charger → battery/Mac)
- Stats dashboard (health, design vs max capacity, cycles, temp history, power consumption graph 5/15/30-min averages)
- Apple Shortcuts actions (set/get limit, pause, discharge, top up, calibrate, LED, temps, low/high power mode)
- Menubar customization (icon styles, show %, stats in bar, hide icon, decimals)
- Launch at login, auto-updates, notifications (limit reached, discharge complete, heat, calibration events)

**Known quirks to design around:**
- Sleep is the hard problem: macOS controls charging during sleep on Apple Silicon; batteries creep to 100% overnight or, conversely, charging gets wrongly blocked. Mitigations: "disable sleep until limit", careful sleep/wake hooks.
- Powered-off Macs always charge to 100% (hardware, can't fix).
- macOS native tiered Charge Limit (15 Sequoia; 80/85/90/95/100 steps in 26.4) is firmware-persistent — consider optional integration since it survives sleep/shutdown.
- Must tell users to disable Optimized Battery Charging.
- Clean uninstall must reset limit to 100%; macOS updates can reset SMC state.
- AlDente has no CLI (Shortcuts only) — an Enso CLI would be a genuine edge.

### Research 3 — Liquid Glass / MenuBarExtra / helper / distribution (complete)

**Liquid Glass (macOS 26 SDK, stable through 26.5):**
- Building against macOS 26 SDK restyles standard controls for free (popovers, sliders, toggles, buttons). `MenuBarExtra` `.window` popover picks up glass automatically.
- Custom surfaces: `.glassEffect(_:in:)` (`Glass.regular`/`.clear`, `.tint()`, `.interactive()`), `GlassEffectContainer(spacing:)` (required when multiple glass views are near each other — glass can't sample glass), `glassEffectID`/morphing, `.buttonStyle(.glass)`/`.glassProminent`.
- 26.1 added user-level Clear vs Tinted appearance — automatic, test both. Don't hardcode opacity.
- App icon via Icon Composer → single layered `.icon` file.

**Menu bar app:**
- `MenuBarExtra` + `.menuBarExtraStyle(.window)`, root view fixed width (~320), `Settings` scene, `LSUIElement=YES` (no Dock icon → must provide Quit button). Settings-window opening from LSUIElement app is a known trap: activate app first (`NSApp.activate`) then open settings.
- Launch at login: `SMAppService.mainApp.register()/unregister()`, read `.status` fresh (user can toggle in System Settings).

**CRITICAL CONSTRAINT — privileged helper without paid Apple account:**
- Modern path `SMAppService.daemon` (embedded plist + BundleProgram + XPC with `setCodeSigningRequirement`) **requires Developer ID signing to register — ad-hoc signed daemons fail**. User has no paid account.
- Fallback (what charlie0129/batt does): classic launchd daemon — copy helper binary + plist into `/Library/PrivilegedHelperTools` / `/Library/LaunchDaemons` via one-time admin-authenticated install (osascript admin prompt or sudo CLI), communicate via XPC/Unix socket. Works unsigned. Design the privilege layer behind a protocol so SMAppService.daemon can be swapped in if a Developer ID cert arrives later.
- Gatekeeper on Tahoe: right-click→Open bypass is gone; unsigned app install requires System Settings → Privacy & Security → "Open Anyway", or `xattr -dr com.apple.quarantine`. Document clearly in README. Prefer zip/DMG of .app, not .pkg.
- App Store distribution impossible (sandbox forbids SMC/root helper) — expected.
- Sparkle 2 auto-updates possible but adds signing complexity; for unsigned FOSS, simpler: in-app "check for updates" hitting GitHub Releases API + Homebrew cask (`brew install --cask` handles quarantine better with `--no-quarantine`).

### Research 2 — SMC mechanics + prior art (complete)

**How charge limiting works on Apple Silicon:** No hardware "limit to N%" register. Apps run a root daemon with a maintain loop (~10s poll + hysteresis) that toggles a charging-inhibit SMC key around the target.

**SMC keys (exact semantics):**
- Charging inhibit, pre-Tahoe: `CH0B` + `CH0C` (u8): write `0x02` both = inhibit, `0x00` = allow.
- Charging inhibit, Tahoe firmware: **`CHTE` (u32)**: `01 00 00 00` = inhibit, zeros = allow. `CH0B/CH0C` gone on updated units — must probe at startup and pick key set (OpenDente/batt pattern).
- Force discharge / adapter-disable: `CH0I` (u8, 1=discharge on AC), `CH0J`; Tahoe: `CHIE` (0x8=disable adapter, 0x0=enable).
- Apple's fixed 80% flag: `CHWA` (1=80% limit) — optional "defer to Apple" mode only.
- MagSafe LED: `ACLC` — 0x00 system, 0x01 off, 0x03 green, 0x04 amber, 0x05–0x07 error blinks.
- Telemetry: `B0CT` cycles, `BUIC` charge %, `TB0T/TB1T/TB2T` battery temps, `ID0R/VD0R/PDTR` DC-in, `B0AC/B0AV/PPBR` battery current/voltage/power.
- SMC I/O: IOServiceOpen("AppleSMC") + IOConnectCallStructMethod with SMCParamStruct (two-phase: READ_KEYINFO then read/write bytes).

**Battery info without root** (for UI): IOPowerSources API + `AppleSmartBattery` IORegistry node — CycleCount, DesignCapacity, AppleRawMaxCapacity (health %), Temperature, Voltage, Amperage, IsCharging, ExternalConnected, TimeRemaining, AdapterDetails.

**Sleep/wake template (from batt — the fix for "charges to 100% overnight"):**
1. Root daemon registers `IORegisterForSystemPower`.
2. On `SystemWillSleep` (unvetoable, lid close): proactively disable charging if limit < 100, delay next maintain cycle ~60s.
3. On wake: delay control ~30s; optionally forced top-up loop.
4. On `CanSystemSleep`: veto idle sleep via `IOCancelPowerChange` when actively maintaining ("prevent idle sleep" option); `kIOPMAssertionTypePreventSystemSleep` assertion for dark-wake charging.

**macOS version history that matters:** Sequoia 15 added kernel entitlement enforcement that killed unsigned CLI writers of `BCLM`/`CHWA` (bclm dead) but root daemons writing CH0B/CH0C kept working; 15.5 silent SMC firmware update broke AlDente temporarily; Tahoe 26 swapped to CHTE/CHIE; 26.4 added Apple's native 80–100% (5% steps) Charge Limit — Enso must detect/coexist (toggle like AlDente's).

**Prior art assessment:** batt (Go daemon + unix socket, best sleep/wake logic, has CHTE support), BatFi (Swift, SMAppService + XPC codesign pinning — requires paid cert), Battery Toolkit (3-process defense in depth), OpenDente (SwiftUI + SMAppService, probes CHTE vs CH0B/C), actuallymentor/battery (sudoers hack — avoid). Validation needed on our machine: exact CHTE/CHIE behavior (root test during implementation).

## Final Plan

### Architecture

Three ad-hoc-signed targets in a committed `Enso.xcodeproj`, all logic in a local SPM package so contributors build with plain Xcode and CI runs `swift test` without the app:

```
enso/
├── Enso.xcodeproj                  # 3 targets: Enso (app), com.enso.daemon, ensoctl
├── Packages/EnsoCore/
│   ├── Sources/EnsoShared/         # XPC protocol, DTOs, EnsoConfig (Codable, versioned), DAEMON_PROTOCOL_VERSION
│   ├── Sources/EnsoSMC/            # SMCConnection (IOKit AppleSMC), SMCCapabilities key-probe, MockSMC/DryRunSMC
│   ├── Sources/EnsoBattery/        # AppleSmartBattery IORegistry reader + IOPowerSources change stream
│   ├── Sources/EnsoEngine/         # ChargingStateMachine — pure, no IOKit, fully unit-tested
│   └── Tests/                      # engine scenario+property tests, SMC struct packing, config validation
├── Apps/Enso/                      # SwiftUI MenuBarExtra (.window, ~320pt, LSUIElement), Settings, HelperInstaller, DaemonClient
├── Daemon/EnsoDaemon/              # main, XPCListener, MaintainLoop (10s tick), PowerEvents, SleepAssertions, DaemonStore
├── CLI/ensoctl/                    # XPC client CLI (dev harness day 1, public v0.2 — an edge AlDente lacks)
├── Scripts/                        # com.enso.daemon.plist.template, install-daemon.sh, uninstall.sh, package-release.sh
├── .github/workflows/              # ci.yml, release.yml
└── docs/                           # ARCHITECTURE.md, TESTING.md, SMC-KEYS.md + design spec
```

**Split of responsibility:** the root daemon owns ALL charging decisions (limits enforced with app quit / before login / in dark wake); the app is pure UI + config + install orchestration. App crash ⇒ daemon keeps maintaining; graceful quit sends `appWillQuit` and daemon keeps maintaining or resets to 100% per user setting.

**SMC strategy:** `SMCCapabilities` probes at daemon start, after every wake, and after write-verify failures → picks `.tahoe(CHTE/CHIE)` or `.legacy(CH0B+CH0C, CH0I)`. Every write is read-back-verified; 3 consecutive failures → re-probe → if nothing works, failsafe-allow + "unsupported firmware" banner. CHWA used only for optional "defer to Apple's native limit" coexistence mode (macOS 26.4 native limit detection + toggle). MagSafe LED via ACLC.

**Engine (pure function `step(input, inout memory) -> output`)** — priority order, first match wins:
0. Failsafe: SoC ≤ 10% or no working key or SMC error streak → allow charging, cancel tasks. Never overridable.
1. No adapter → allow (never leave stale inhibit).
2. Pre-sleep: proactively inhibit if limit < 100 (fixes charges-to-100-overnight); post-wake 30s settle: hold.
3. Heat protection: temp ≥ threshold → inhibit; resume after temp < threshold−2°C AND 5 min.
4. Calibration sub-machine: chargeTo100 → hold 1h → dischargeTo15 → chargeTo100 → hold 1h → back to limit.
5. Top Up: allow until 100%, then clear.
6. Discharge task: forceDischarge until target (floor 15%).
7. Maintain with hysteresis: ≥limit inhibit, ≤lower allow, between = latched. Sailing = user lower bound; plain limit = limit−1.
Sleep-block output is orthogonal ("disable sleep until limit"). Schedules live outside the engine (daemon ScheduleEvaluator, fires on tick/wake for "next opportunity" semantics).

**Privilege model (no paid Apple account — hard constraint):** classic LaunchDaemon, not SMAppService.daemon (which rejects ad-hoc signing). First-run onboarding sheet → one admin prompt (osascript) runs `install-daemon.sh`: copies daemon to `/Library/PrivilegedHelperTools/com.enso.daemon`, renders plist (MachServices `com.enso.daemon.xpc`, KeepAlive) into `/Library/LaunchDaemons`, writes install-time random shared secret to root-only + user-only files, `launchctl bootstrap`. XPC = NSXPCConnection, handshake(secret) gate, minimal protocol (getStatus / applyConfig with daemon-side clamping 50–100 / runCommand enum / prepareUninstall) — never raw SMC access. Upgrade via `DAEMON_PROTOCOL_VERSION` handshake mismatch → re-run installer. Uninstall restores all keys + limit 100. Threat model documented honestly; codesign pinning slots in if a cert ever arrives.

**Safety guard rails (code, not discipline):** limit clamped 50–100 in three layers; discharge floor 15%; 10% failsafe; restore-on-SIGTERM; allow-on-no-adapter; launchd KeepAlive respawn + state resume; standalone `Scripts/uninstall.sh` for app-deleted case.

**UI:** Liquid Glass free from macOS 26 SDK; `.glassEffect`/`GlassEffectContainer`/`.buttonStyle(.glass)` for custom surfaces; test Clear vs Tinted appearance; `NSApp.activate` before opening Settings (LSUIElement trap); SMAppService.mainApp launch-at-login toggle (default off); Quit button in popover.

### Release roadmap (GitHub Releases, tag-driven)

- **v0.1.0 Core:** SMC layer + probe; daemon (maintain loop, sleep/wake, failsafe); installer/uninstaller; XPC+secret; menu bar UI with limit slider + status icon + basic stats (SoC, cycles, health %, temp, adapter); launch at login; quit behavior; ensoctl (dev); README with Tahoe Gatekeeper instructions (`xattr -dr com.apple.quarantine` / "Open Anyway").
- **v0.2.0 Control:** Top Up; manual discharge; MagSafe LED; notifications (limit reached, discharge done); public ensoctl.
- **v0.3.0 Comfort:** Sailing mode; heat protection; disable-sleep-until-limit; menu bar customization; hardware-% (BUIC) toggle.
- **v0.4.0 Automation:** Calibration (+scheduling); Schedules; automatic discharge; native-limit coexistence toggle.
- **v0.5.0 Insight:** history persistence + stats dashboard graphs; Power Flow view; more notifications.
- **v0.6.0 Ecosystem:** App Intents/Shortcuts; clamshell discharge; in-app update check (GitHub Releases API — no Sparkle, unsigned); Homebrew tap cask (`--no-quarantine`).
- **v1.0.0:** polish, docs, diagnostics export, accessibility.

### Build order within v0.1

1. Repo hygiene (remove stray firebase-debug.log, .gitignore, README skeleton, LICENSE MIT) + commit design doc into `docs/`.
2. EnsoCore package + ChargingStateMachine with full test suite (pure Swift, fastest feedback).
3. EnsoSMC read paths + `ensoctl debug dump-keys`; probe real hardware (read-only, safe).
4. Daemon: XPC + maintain loop over DryRunSMC; then installer scripts.
5. First real SMC writes following the manual hardware protocol below; then sleep/wake handling.
6. SwiftUI app UI last (thinnest layer). Ship v0.1.0.

Git: commit at each coherent step, push to `origin/main` regularly; releases via `gh release create` on tags with zip built by `ditto -c -k --keepParent` (preserves xattrs/signatures — never plain zip).

### Verification

- **CI (every push):** `swift test` on EnsoCore (engine scenario + property tests: SoC never exceeds limit+2 steady-state, never inhibit ≤10%, discharge never below floor; simulated clock for hysteresis; capability-probe decision table with fake key inventories) + `xcodebuild` compile of all targets. Runner `macos-26`, fallback documented.
- **Manual hardware protocol (this M4 Air, never below 20% SoC, snapshot keys first via `ensoctl debug dump-keys`, auto-restore trap on any error/Ctrl-C):** (1) first inhibit write at 60–80% plugged in → confirm IsCharging=false within 30s → restore → confirm resume; (2) maintain at limit 70 for 1h ±1%; (3) `pmset sleepnow` + overnight lid-close test, morning SoC ≤ limit+2; (4) discharge 80→75 with auto-stop; (5) chaos: kill -9 daemon mid-inhibit (respawn+resume ≤30s), reboot while limited (reapplied ≤1 tick); (6) full uninstall → keys back to snapshot. Requires user's admin password at install steps.
- Each release: fresh-download install test on this machine (quarantine attr present) to validate the documented Gatekeeper flow.

### Key risks

- Firmware/SMC changes (CHTE precedent) → probe+verify+failsafe+SMC-KEYS.md registry.
- Apple further locking unsigned root SMC writes → CH0B/C/CHTE proven working from unsigned root daemons on Sequoia+ (batt); CHWA optional-only.
- Gatekeeper friction (Tahoe removed right-click bypass) → README-first docs, Homebrew `--no-quarantine` later.
- XPC without codesign pinning → minimal clamped protocol + install secret; documented threat model.
