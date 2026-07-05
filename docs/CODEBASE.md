# The Enso Codebase, In Depth

This is the guided tour: read it top to bottom before your first PR and you
will know where everything lives, why it is shaped that way, and which parts
bite. It describes the code as it **is** — when this document and the source
disagree, the source wins and this file has a bug (please fix it).

Companion documents:

- [ARCHITECTURE.md](ARCHITECTURE.md) — the one-page overview version of this file.
- [SMC-KEYS.md](SMC-KEYS.md) — the SMC key registry and which entries are hardware-verified.
- [TESTING.md](TESTING.md) — CI coverage and the manual hardware protocol.
- [DESIGN.md](DESIGN.md) — the original design spec (historical; code wins).

---

## 1. The big picture

Enso is **three executables built from one SwiftPM tree**, talking over XPC:

```
┌───────────────────────────────┐          ┌────────────────────────────────────┐
│ Enso.app          (user, GUI) │          │ com.enso.daemon (root LaunchDaemon)│
│  SwiftUI MenuBarExtra         │   XPC    │  Daemon.tick() every 10 s          │
│  Settings, HelperInstaller    │◄────────►│  ChargingStateMachine (pure)       │
│  BatteryReader (read-only)    │   mach   │  ChargingControl → SMC writes      │
├───────────────────────────────┤  service │  PowerEvents (sleep/wake)          │
│ ensoctl           (user, CLI) │          │  DaemonStore (config/memory/secret)│
└───────────────────────────────┘          └────────────────────────────────────┘
```

The single most important design rule:

> **The daemon owns every charging decision. The app is UI and configuration
> only.** If the app crashes, is quit, or the user logs out, the daemon keeps
> enforcing the limit. The app never computes "should we charge" — it only
> displays what the daemon reports and edits the config the daemon owns.

Everything else follows from three constraints:

1. **SMC writes need root** — hence the privileged daemon.
2. **No paid Apple Developer account** — hence a classic LaunchDaemon (not
   `SMAppService.daemon`, which rejects ad-hoc signing), a shared-secret XPC
   handshake (not codesign pinning), and quarantine-aware distribution.
3. **This code toggles charging on real batteries** — hence the pure,
   exhaustively-tested engine and layered failsafes.

## 2. Repository layout and build system

```
enso/
├── Package.swift                 # root SPM package: 3 executable targets
├── Packages/EnsoCore/            # library package: ALL logic lives here
│   ├── Sources/EnsoShared/       #   config, DTOs, XPC protocol
│   ├── Sources/EnsoEngine/       #   the pure charging state machine
│   ├── Sources/EnsoSMC/          #   AppleSMC I/O, capability probe, test doubles
│   ├── Sources/EnsoBattery/      #   IORegistry battery snapshots
│   └── Tests/                    #   the whole test suite (45 tests)
├── Apps/Enso/Sources/            # SwiftUI menu bar app (thin)
├── Daemon/EnsoDaemon/            # ensod — the root daemon (thin)
├── CLI/ensoctl/                  # the CLI (thin)
├── Scripts/                      # bundle assembly, installer, packaging
├── install.sh                    # the public curl-one-liner installer
└── .github/workflows/            # ci.yml (test+build), release.yml (tag → release)
```

**There is deliberately no `.xcodeproj`.** Everything is pure SwiftPM: the
root `Package.swift` declares three `executableTarget`s (`Enso`, `ensod`,
`ensoctl`) that depend on the local `Packages/EnsoCore` library package.
`xed .` gives you a full Xcode experience anyway, CI is a plain `swift test`
+ `swift build`, and there is no project file to merge-conflict. Keep it that
way — an app bundle is assembled from the SPM products by a shell script:

- `Scripts/make-app.sh` — `swift build -c release`, then builds
  `dist/Enso.app` by hand: `Info.plist` from a template (version read out of
  `EnsoConfig.swift`), the `Enso` binary into `Contents/MacOS/`, and
  `ensod` + `ensoctl` + install scripts + LaunchDaemon plist template into
  `Contents/Resources/`. Finally ad-hoc codesigns (`codesign -s -`)
  the daemon, the CLI, and the bundle.

The executables are **thin by policy**. `Apps/Enso`, `Daemon/EnsoDaemon`, and
`CLI/ensoctl` contain wiring, I/O, and UI. Any logic worth testing goes in
`Packages/EnsoCore`, where `swift test` can reach it without hardware.

## 3. Module by module (`Packages/EnsoCore`)

### 3.1 `EnsoShared` — the contract

`EnsoConfig.swift`:

- `DAEMON_PROTOCOL_VERSION` — bumped **only** when the XPC protocol or config
  schema changes incompatibly. A mismatch at handshake is the *only* thing
  that triggers the "helper update required" flow in the app. Daemon version
  strings are allowed to differ (UI-only releases must not nag for an admin
  password).
- `ENSO_VERSION` — the marketing version, shared by all three binaries.
  `make-app.sh` greps it out of this file for the bundle's `Info.plist`.
- `ChargeLimits` — the safety constants: limit clamp **50–100**, discharge
  floor **15**, failsafe SoC **10**. These are load-bearing; see §8.
- `EnsoConfig` — the single versioned config document, `Codable`. The app
  edits a copy, the daemon owns the persisted truth. `validated()` clamps
  every field into its legal range; the daemon calls it on **everything**
  arriving over XPC, so UI-side clamping is a convenience, not the guarantee.

`DaemonAPI.swift`:

- `EnsoDaemonXPC` — the complete privileged surface: `handshake`,
  `getStatus`, `applyConfig`, `runCommand`. Payloads are JSON `Data` so
  `NSSecureCoding` stays trivial. There is deliberately **no "write an
  arbitrary SMC key" method** — commands are a fixed enum (`DaemonCommand`).
- `DaemonStatus` — the status snapshot. Note that fields added after v0.1
  (`recentEvents`, `hasMagSafeLED`) are optional: an app must be able to
  decode a status payload from an older daemon. Follow that pattern for every
  future field.

`ChargeAction.swift` — the three-valued output of the engine (`allow` /
`inhibit` / `forceDischarge`) and `LEDState`.

### 3.2 `EnsoEngine` — the pure state machine

`ChargingStateMachine.swift` is the safety-critical heart, and it is a pure
function:

```swift
ChargingStateMachine.step(input: EngineInput, memory: inout EngineMemory) -> EngineOutput
```

- **No IOKit. No timers. No `Date()`** — the wall clock arrives as
  `input.now`. This is what makes charge/sleep/heat scenarios exhaustively
  testable in CI with a simulated clock and battery.
- `EngineMemory` is `Codable` and persisted by the daemon after every tick
  that changes it, so a daemon crash/restart resumes mid-task (a kill -9
  during a discharge has been tested live; the discharge continued).
- `EngineOutput` = `(action, sleepBlock, led, events)` — the daemon applies
  the action to the SMC, holds/releases sleep assertions for `sleepBlock`,
  drives the MagSafe LED, and turns `events` into notifications.

**The priority ladder** (first match returns; the order encodes hard-won
lessons — do not reorder casually):

| # | Rule | Why it is exactly here |
|---|------|------------------------|
| P0 | **Failsafe**: SoC ≤ 10, no working inhibit key, or SMC error streak ≥ 3 → `allow`, cancel all tasks | Nothing may override "the battery is nearly empty" or "we no longer trust our writes". |
| — | **Post-wake settle**: hold `memory.lastAction`, decide nothing | IOKit's adapter/battery readings are stale for ~30 s after wake. Deciding anything from them cancels tasks that shouldn't be cancelled (live bug #2). Must come **before** any adapter-based rule. |
| — | **Adapter-gone debounce**: unplug handling requires 2 consecutive "disconnected" ticks | One stale reading must not count as an unplug. |
| P1 | **No adapter** → `allow`, cancel top-up/discharge (calibration merely pauses) | Never leave a stale inhibit on an unplugged Mac. **Caveat**: skipped while `memory.lastAction == .forceDischarge`, because force-discharge works by disabling the adapter in firmware — the "unplug" is our own doing (live bug #1). |
| P2 | **Pre-sleep**: inhibit if `stopChargingWhenSleeping` and target < 100 | Fixes the classic "charged to 100% overnight" failure — macOS keeps charging during sleep, so we close the gate *before* sleeping. |
| P3 | **Heat protection**: inhibit at ≥ threshold; resume only after temp < threshold − 2 °C **and** a 5-minute cooldown | Inhibit only — never force-discharge a hot battery. Hysteresis prevents flapping around the threshold. |
| P4 | **Calibration sub-machine**: chargeToFull → holdFull (1 h) → dischargeToFloor (15%) → rechargeToFull → finalHold (1 h) | A long-running multi-phase task; each phase maps to one action. |
| P5 | **Top up**: `allow` until SoC ≥ 100, or ≥ 99 sustained for 10 min | macOS itself declines to charge the last few percent for a while (top-off behavior observed live at ~94–100%); the 99%-window keeps top-up from hanging forever. |
| P6 | **Discharge task**: `forceDischarge` until `max(target, 15)` | The floor is applied here *and* when the task is created. |
| P7 | **Maintain**: at/above limit → `inhibit` (or `forceDischarge` if `automaticDischarge`); at/below the lower bound → `allow`; inside the band → keep the latched action | The lower bound is `sailingLowerLimit` when sailing is enabled, otherwise `limit − 1`. Hysteresis stops the 10 s tick from micro-toggling the SMC. |

Two orthogonal outputs are computed in `finish(...)`:

- **`sleepBlock`** — true while an AC task runs, or when the user enabled
  `preventSleepUntilLimit` and we're still charging to the limit. Note the
  force-discharge adapter caveat applies here too: during our own discharge
  the adapter *reads* disconnected but must be treated as present.
- **LED** — in `enso` mode: green at limit, amber while charging/discharging,
  handed back to the system when genuinely unplugged.

**Back-compat rule for `EngineMemory`:** the daemon persists it as JSON, and
an upgraded daemon must decode the previous version's file. Every field added
after v0.1 gets `decodeIfPresent` + a default in the custom `init(from:)`
(see `adapterGoneStreak`). Do the same for anything you add.

### 3.3 `EnsoSMC` — the hardware boundary

`SMCConnection.swift` — the AppleSMC IOKit user client:

- `SMCParamStruct` **must be exactly 80 bytes** to match the kernel's C
  layout — that's what the `padding: UInt16` field is for, and a unit test
  pins the size. If you touch this struct and the test fails, the struct is
  wrong, not the test.
- Two-phase I/O via `IOConnectCallStructMethod` selector 2: `getKeyInfo`
  (0x9, cached per key) to learn size/type, then `readBytes` (0x5) /
  `writeBytes` (0x6). Reads work unprivileged; **writes throw unless euid 0**.

`ChargingControl.swift` — engine actions become concrete key writes:

- `SMCCapabilities.probe` decides the **strategy** by testing key existence:
  `CHTE` present → `.tahoe` (macOS 26 firmware), else `CH0B`+`CH0C` →
  `.legacy`, else `.none` (daemon stands down, failsafe). Probed at daemon
  start, after every wake, and after a write-error streak — firmware key
  swaps mid-OS-update are the precedent (Tahoe replaced the legacy keys).
- Every mutating write goes through `writeVerified` (write, read back,
  compare). A failed verify throws; the daemon counts a streak and re-probes
  at 3.
- `apply(action:)` orders the two key writes so the transient state is always
  the safer one (e.g. inhibit before enabling discharge).
- `restoreDefaults()` puts every key Enso may have touched back to stock and
  is deliberately best-effort (`try?` each key) — it runs on SIGTERM,
  uninstall, and quit-with-reset, where "keep going" beats "give up".

`TestDoubles.swift` — `MockSMC` (factories: `tahoeMacBook`, `legacyMacBook`,
`noChargingKeys`; records a write log; can fail the next N writes) and
`DryRunSMC` (wraps the real connection: reads pass through, writes go to a
shadow store and a log line — this is what `ensod --dry-run` uses, and it
lets an unprivileged soak run against real telemetry).

### 3.4 `EnsoBattery` — unprivileged telemetry

`BatteryReader.snapshot()` reads the `AppleSmartBattery` IORegistry node:
SoC, `ExternalConnected`, `IsCharging`, cycle count, temperature, health
(`AppleRawMaxCapacity / DesignCapacity × 100` — which can exceed 100% on a
young battery; the UI caps it at 100 by default for exactly that reason).
`PowerSourceObserver` wraps the IOPowerSources run-loop callback so the app
refreshes immediately on plug/unplug. Used by both the app (directly, no
root needed) and the daemon (as engine input).

## 4. The daemon (`Daemon/EnsoDaemon`)

`main.swift` — refuses to run without root (except `--dry-run`), installs
SIGTERM/SIGINT handlers that call `shutdown()` (restore SMC defaults if
`restoreOnExit`, persist memory), starts the XPC listener and the daemon.

`Daemon.swift` — everything funnels through one serial queue. The constants
that shape behavior:

| Constant | Value | Meaning |
|---|---|---|
| `tickInterval` | 10 s | engine cadence |
| `preSleepSuppression` | 60 s | no ticks right after the pre-sleep tick, so a maintain tick can't re-open charging as the lid closes |
| `postWakeSettle` | 45 s | engine held in `postWakeSettling` after wake; capabilities re-probed when it ends |

Per tick: battery snapshot (+ hardware SoC via `BUIC` if configured, SMC
temperature if available) → `EngineInput` → `step` → `apply(output:)` →
persist memory if changed. `apply` **skips the SMC round-trip when the
action didn't change** — with a 10 s tick, unconditional writes would hammer
the SMC for no reason.

Power events (`PowerEvents.swift`):

- The `kIOMessage*` constants are **defined by hand** (`0xE0000270` etc.)
  because they are C `#define` macros Swift cannot import. Don't go looking
  for the "proper" imported symbols; there aren't any.
- `canSleep` → veto (`IOCancelPowerChange`) iff a sleep-block is active.
- `willSleep` → forced tick in `.preSleep` phase (the engine inhibits if
  configured), then acknowledge — this cannot be vetoed and must be
  acknowledged within 30 s.
- `didWake` → enter `.postWakeSettling` for 45 s.

`SleepAssertion` holds **two** assertions at once, and both are needed:
`PreventSystemSleep` enables lid-closed dark-wake charging but is only
honored on AC — and during a force-discharge macOS *believes* it is on
battery, so without `PreventUserIdleSystemSleep` the Mac falls asleep
mid-discharge (live bug #3).

Events: engine events are stamped into human-readable `StampedEvent`s and
kept in a 20-entry ring buffer that rides along in `getStatus`; the app
notifies about the ones it hasn't seen. The daemon itself never talks to
the notification system — it has no UI session.

## 5. The app (`Apps/Enso/Sources`)

`EnsoApp.swift` — `MenuBarExtra` with `.menuBarExtraStyle(.window)` (Liquid
Glass popover for free on the macOS 26 SDK), a `Settings` scene, and
`LSUIElement` in the Info.plist template (menu-bar-only, so the popover must
provide Quit). Gotcha preserved in the code: **SwiftUI's `SceneBuilder` does
not support `if` around a whole `Scene`** — conditional content goes *inside*
a scene's view, which is how the debug window (env `ENSO_DEBUG_WINDOW`) is
gated.

`AppState.swift` — one 5-second heartbeat drives battery refresh, daemon
status, config sync, and event surfacing. **The config-sync contract**
matters, because it fixed a real bug (a `magSafeLED` change made via
`ensoctl` was silently clobbered by the app's stale copy):

- The daemon's config is the source of truth.
- The app adopts it on first connect **and re-adopts whenever it differs** —
  *except* within 10 s of a local edit (`lastLocalEdit`), so a slider the
  user is dragging doesn't fight the heartbeat.
- Every local push (`pushConfig()`) stamps `lastLocalEdit`.

`DaemonClient.swift` — the XPC client. State machine:
`helperMissing` (binary not at `/Library/PrivilegedHelperTools/com.enso.daemon`)
→ `connecting` → handshake → `ready` / `badSecret` / `needsUpgrade` /
`unreachable`. All calls carry a 3 s timeout via a guarded continuation
(XPC reply blocks are not guaranteed to be called; without the timeout a
dead daemon hangs the UI). **`needsUpgrade` comes only from the handshake's
protocol-version check** — never from comparing version strings.

`HelperInstaller.swift` — runs the bundled `install-daemon.sh` via
`osascript … with administrator privileges` (the one admin prompt). Falls
back to the repo's `Scripts/` when running unbundled from `swift run`
during development.

`NotificationManager.swift` — `UNUserNotificationCenter`; silently no-ops
when there's no bundle identifier (i.e. when run as a bare SPM binary
instead of from the .app).

`Views/MenuBarView.swift` — the 320-pt popover: the `ChargeRing` (SoC ring
with a tick at the limit — the app's signature element), the limit slider
(pushes config on editing-*end*, not per pixel), Top Up / Discharge buttons,
task progress + Stop, helper-state banners, and the stats grid. Battery
health is capped at 100% unless the "Show true battery health" setting is
on — a young battery genuinely measures >100% of design capacity, and
uncapped it reads as a bug to normal users. That's the house UX rule:
**confusing-but-true values ship behind an opt-in toggle.**

`Views/SettingsView.swift` — launch at login (`SMAppService.mainApp`), quit
behavior, sleep toggles, hardware-percentage, MagSafe LED mode (shown only
when `status.hasMagSafeLED == true`), notifications, uninstall-helper (with
confirmation).

## 6. The CLI (`CLI/ensoctl`)

Same XPC client path as the app (same secret file, same handshake):
`status`, `limit N`, `led <system|enso|off>`, `topup`, `discharge N`,
`calibrate`, `cancel`, `uninstall-prepare`, and a `debug` group (`probe` —
which strategy this Mac speaks; `dump-keys` — snapshot of every key Enso
cares about; `battery` — the full snapshot as JSON). It ships inside the app
bundle at `Contents/Resources/ensoctl`. Config edits are a read-modify-write:
`getStatus` → mutate one field → `applyConfig` — so they compose with the
app's re-adopt logic instead of clobbering unrelated fields.

## 7. Install, upgrade, uninstall — what lands where

One admin prompt runs `Scripts/install-daemon.sh` as root:

| Path | What | Owner/mode |
|---|---|---|
| `/Library/PrivilegedHelperTools/com.enso.daemon` | the `ensod` binary | root, 755 |
| `/Library/LaunchDaemons/com.enso.daemon.plist` | MachServices + RunAtLoad + KeepAlive | root, 644 |
| `/Library/Application Support/com.enso.daemon/` | `config.json`, `engine-memory.json`, `secret` | root; secret 600 |
| `~/Library/Application Support/Enso/secret` | user-readable copy of the secret | user, 600 |

The secret is a `uuidgen` generated **once** and preserved across upgrades
(so upgrading the daemon doesn't break the app's authentication). XPC
clients present it in `handshake()`; the daemon compares in constant time.

**Threat model, honestly:** without Developer ID signing we cannot pin the
XPC client's code signature. The secret keeps other local users and
unprivileged processes out; it does not stop malware running *as the same
user* (it can read the same secret file). That is why the XPC surface is a
fixed command enum with daemon-side re-validation — the worst a bypass
achieves is setting a charge limit within 50–100%. If a Developer ID cert
ever arrives, `setCodeSigningRequirement` slots into `DaemonClient` and the
listener delegate without touching anything else.

Upgrades: `install-daemon.sh` is idempotent — `launchctl bootout`, replace
binary+plist, keep secret, `bootstrap` + `kickstart`. Uninstall is two
stages: XPC `prepareUninstall` (limit → 100, all touched SMC keys restored,
LED → system) then `Scripts/uninstall.sh` under sudo removes binary, plist,
and support dir. `Scripts/uninstall.sh` also works standalone for users who
already trashed the app.

## 8. Safety: the layers, and why you must not remove any

This software can stop a laptop from charging. The failure mode of a bug is
not "the app crashes", it's "the user's Mac dies at 3% and won't charge".
Every layer below has a reason:

1. **Engine P0 failsafe** — SoC ≤ 10% / no working key / write-error streak
   ≥ 3 → allow charging unconditionally. Cancels every task.
2. **Limit clamp 50–100** enforced three times: UI, `EnsoConfig.validated()`
   on receipt in the daemon, and `ChargeLimits.clamp`.
3. **Discharge floor 15%** — applied when a discharge task is created *and*
   on every engine step.
4. **Write-verify on every SMC write**; unverifiable → error streak →
   re-probe → `.none` strategy → failsafe.
5. **Never write unknown keys** — only the keys in `SMC-KEYS.md`, only
   through `ChargingControl`.
6. **No stale inhibit off AC** — P1, with the debounce and force-discharge
   caveats documented above.
7. **Restore on every exit path** — SIGTERM/SIGINT handler, `prepareUninstall`,
   quit-with-reset; all call `restoreDefaults()`.
8. **launchd KeepAlive + persisted `EngineMemory`** — a crashed daemon
   respawns and reconciles within one tick.

If a change you're making requires weakening any of these, the change is
wrong. Find another way.

## 9. Release & distribution pipeline

- `Scripts/package-release.sh` = `make-app.sh` → `dist/Enso.zip` via
  `ditto -c -k --keepParent` (**never** plain `zip` — ditto preserves
  signatures and extended attributes) + SHA-256 → `make-dmg.sh`
  (`hdiutil` UDZO with an `/Applications` symlink and a READ-ME) →
  `RELEASE_NOTES.md`.
- Pushing a tag `v*` triggers `.github/workflows/release.yml`: package on a
  `macos-26` runner, `gh release create` with the artifacts. CI
  (`ci.yml`) runs `swift test` + release build + bundle assembly on every
  push/PR. (`macos-26` is the runner label needed for the macOS 26 SDK;
  fall back to `macos-latest` if it disappears.)
- **Release checklist:** bump `ENSO_VERSION` in `EnsoConfig.swift`, update
  `CHANGELOG.md`, commit, `git tag vX.Y.Z`, push the tag. Bump
  `DAEMON_PROTOCOL_VERSION` *only* if the XPC/config contract changed.
- `install.sh` (repo root) is the recommended install path:
  `curl … | bash` fetches the latest release zip and installs to
  `/Applications`. The whole point: **quarantine (`com.apple.quarantine`) is
  attached by browsers, not by `curl`**, so a Terminal install of an
  unsigned app launches with zero Gatekeeper friction. DMG/zip downloads
  from a browser need "Open Anyway" or `xattr -dr com.apple.quarantine` —
  that's Apple's tax on unsigned FOSS, not a bug.

## 10. Hardware truths (verified live on a MacBook Air M4, macOS 26.5.1)

These were discovered by testing, not by reading — code and tests encode all
of them, and future work must not "fix" them away:

| Fact | Consequence in code |
|---|---|
| `CHTE` = `01 00 00 00` inhibits charging; zeros allow. `CHIE` = `0x08` disables the adapter (force-discharge); `0x00` restores. | The Tahoe strategy in `ChargingControl`. |
| **Force-discharge makes IOKit report the adapter as disconnected.** The "unplug" is Enso's own doing. | Engine skips the unplug rule while `lastAction == .forceDischarge`; sleep-block and LED treat the adapter as present. |
| **Post-wake, adapter/battery readings are stale for up to ~30 s.** | 45 s `postWakeSettling` hold *before* any adapter decision + 2-tick unplug debounce. |
| `PreventSystemSleep` is only honored on AC — and during force-discharge macOS thinks it's on battery. | `SleepAssertion` holds `PreventUserIdleSystemSleep` too. |
| macOS itself declines to charge in the ~94–100% band for a while (top-off behavior). | Top-up completes on "≥ 99% sustained 10 min", not only on == 100. |
| `ACLC`: `0x00` system, `0x01` off, `0x03` green, `0x04` amber — verified visually. | LED driving in the daemon. |
| `CHWA` is absent on this firmware; `CH0B/CH0C` absent too (Tahoe). | The legacy strategy is literature-based and untested on real hardware — community reports from M1–M3 pre-Tahoe machines are wanted. |

## 11. How to add a feature (the grain of the codebase)

Work bottom-up; each step is testable before the next exists:

1. **Config**: add a field to `EnsoConfig` with a default and, if needed,
   clamping in `validated()`. Defaults must decode-compat: `Codable`
   synthesis handles missing keys only via custom `init(from:)` — copy the
   `EngineMemory` pattern if the field must decode from older JSON.
2. **Engine**: add the rule to `ChargingStateMachine.step` at the *right
   priority* (argue about the position — it matters more than the rule), and
   an `EngineEvent` if users should hear about it.
3. **Tests first-class**: a scenario test in `ChargingStateMachineTests` and,
   if the rule interacts with time or charging curves, extend the property
   tests in `SimulatedBatteryPropertyTests`.
4. **Daemon**: wire new inputs into `tick()` / new commands into
   `run(command:)` (extend `DaemonCommand` — that changes the protocol, see
   the versioning rule) / new status into `DaemonStatus` (**optional field**).
5. **UI/CLI last**: they only render and edit; by this point the feature
   already works via `ensoctl`.

Charging-behavior changes additionally need the manual hardware pass in
[TESTING.md](TESTING.md) before release.
