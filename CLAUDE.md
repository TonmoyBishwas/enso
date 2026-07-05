# CLAUDE.md

Guidance for AI coding agents (and a fast orientation for humans) working on
Enso — a free, open-source battery charge limiter for Apple Silicon MacBooks.
Read `docs/CODEBASE.md` for the full tour; this file is the rules.

## What this is

Three SwiftPM executables, one library package, no `.xcodeproj` (on purpose):

- **`Enso.app`** (`Apps/Enso`) — SwiftUI menu bar UI. Displays and edits; never decides.
- **`ensod`** (`Daemon/EnsoDaemon`) — root LaunchDaemon. Owns *all* charging
  decisions: a 10 s tick feeds a pure state machine whose output toggles SMC
  charging keys.
- **`ensoctl`** (`CLI/ensoctl`) — CLI over the same XPC service.
- **`Packages/EnsoCore`** — all logic and all tests: `EnsoShared` (config/DTOs/
  XPC contract), `EnsoEngine` (pure state machine), `EnsoSMC` (AppleSMC I/O),
  `EnsoBattery` (IORegistry telemetry).

Hard project constraints: Apple Silicon only; **no paid Apple Developer
account** (ad-hoc signing, classic LaunchDaemon — `SMAppService.daemon`
rejects ad-hoc signatures; shared-secret XPC auth — codesign pinning is
unavailable); pure SPM (don't add an Xcode project).

## Commands

```bash
swift test --package-path Packages/EnsoCore   # the test suite (~45 tests) — run before claiming anything works
swift build                                   # compile all three executables
./Scripts/make-app.sh                         # assemble dist/Enso.app (release build, ad-hoc signed)
./Scripts/package-release.sh                  # zip + DMG + release notes in dist/
```

Release = bump `ENSO_VERSION` in `Packages/EnsoCore/Sources/EnsoShared/EnsoConfig.swift`,
update `CHANGELOG.md`, commit, tag `vX.Y.Z`, push the tag — GitHub Actions
builds and publishes. Bump `DAEMON_PROTOCOL_VERSION` **only** when the XPC
protocol or config schema changes incompatibly.

## Safety guardrails — non-negotiable

This code stops laptops from charging. A bug here doesn't crash an app; it
strands someone's Mac at 3%. Never weaken, reorder away, or "simplify out":

- The engine **P0 failsafe**: SoC ≤ 10%, no working inhibit key, or 3+ SMC
  write failures → charging allowed unconditionally, all tasks cancelled.
- The **limit clamp (50–100)**, the **discharge floor (15%)**, and daemon-side
  `validated()` on every config arriving over XPC.
- **Every SMC write is read-back-verified** (`writeVerified`). Never add an
  unverified write path.
- **Never write an SMC key that isn't documented in `docs/SMC-KEYS.md`**, and
  never add raw SMC access to the XPC surface — commands stay a fixed enum.
- **Restore-to-stock on every exit path** (SIGTERM, uninstall, quit-with-reset
  → `restoreDefaults()`), and never leave an inhibit latched on a Mac that's
  actually unplugged.
- Live hardware testing (anything that actually writes SMC keys) happens
  **only** with the human's explicit go-ahead, charger plugged in, SoC above
  20%, and a `ensoctl debug dump-keys` snapshot taken first. Installing/
  upgrading the root helper prompts for an admin password — that is always
  the human's call.

## Design rules (violating these has caused real bugs)

- **The daemon owns charging decisions; the app is UI only.** New behavior
  goes engine → daemon → UI, never the reverse.
- **The engine stays pure.** No IOKit, no timers, no `Date()` inside
  `ChargingStateMachine.step` — time and all sensor state arrive in
  `EngineInput`. This purity is why the safety logic is testable in CI.
- **Engine rule order is load-bearing.** Failsafe first; post-wake settle
  *before* any adapter-based rule; the unplug rule must skip when
  `memory.lastAction == .forceDischarge` (force-discharge disables the
  adapter in firmware, so the "unplug" is Enso's own doing). See the ladder
  table in `docs/CODEBASE.md` §3.2 before touching `step`.
- **The daemon's config is the source of truth.** The app re-adopts daemon
  config on its heartbeat whenever it changed externally, except within 10 s
  of a local edit. Don't cache config in the app and push it back blindly —
  that exact bug silently reverted `ensoctl` changes.
- **Wire-format compatibility:** new fields in `DaemonStatus` are optional;
  new fields in `EngineMemory` use `decodeIfPresent` + default in the custom
  `init(from:)`. An old daemon's JSON must always decode.
- **`needsUpgrade` comes only from the handshake protocol-version check** —
  never from comparing version strings. UI-only releases must not nag users
  for an admin password.
- **XPC calls need timeouts.** Reply blocks aren't guaranteed to fire; every
  call in `DaemonClient` races a 3 s timer via a guarded continuation. Keep
  that pattern.
- **UX rule:** hide confusing-but-true values behind an opt-in toggle
  (example: battery health > 100% is real on young batteries, but it's capped
  at 100% by default with a "Show true battery health" setting, because
  uncapped it reads as a bug).

## Known traps (each of these cost real debugging time)

- **SwiftUI `SceneBuilder` can't wrap a whole `Scene` in `if`** — it fails
  with an unhelpful "failed to produce diagnostic". Put the condition inside
  the scene's content view.
- **`kIOMessageSystemWillSleep` etc. don't import into Swift** (C `#define`
  macros). They're hand-defined in `Daemon/EnsoDaemon/PowerEvents.swift`.
- **`SMCParamStruct` must be exactly 80 bytes** — the `padding` field is
  structural, and a unit test pins the size. Never reorder/add fields.
- **Post-wake, IOKit adapter/battery readings are stale for ~30 s** — hence
  the 45 s settle phase and the 2-tick unplug debounce. Don't make adapter
  decisions from a single reading.
- **Sleep assertions:** `PreventSystemSleep` is honored only on AC, and during
  a force-discharge macOS *believes* it's on battery — hold
  `PreventUserIdleSystemSleep` as well (see `SleepAssertion`), or the Mac
  sleeps mid-discharge.
- **macOS declines to charge in the ~94–100% band for a while** (top-off).
  Top-up therefore completes on "≥ 99% for 10 min", not only on 100%.
- **Package with `ditto -c -k --keepParent`, never `zip`** — plain zip strips
  the xattrs/signatures and the app won't launch cleanly.
- **The curl installer works because browsers add quarantine and `curl`
  doesn't.** Don't "improve" `install.sh` in ways that reintroduce a
  quarantined download.
- CI runs on the **`macos-26`** runner label (needed for the macOS 26 SDK /
  Liquid Glass). macOS has **no `timeout` command**; zsh has a `log` builtin
  that shadows `/usr/bin/log`.
- The app is `LSUIElement` (menu-bar only): call `NSApp.activate` before
  opening the Settings window, and keep a Quit button in the popover.

## How to verify work

1. `swift test --package-path Packages/EnsoCore` — must be green. Engine or
   SMC changes get new scenario/property tests, not just green existing ones.
2. `./Scripts/make-app.sh` — the bundle must assemble and sign.
3. Behavior changes that touch charging, sleep, or SMC writes additionally
   need the manual hardware protocol in `docs/TESTING.md` — that requires a
   human with a plugged-in Apple Silicon MacBook; ask, don't assume.
4. When docs and code disagree, fix the docs in the same PR.

## Repo etiquette

This is a public repository. Never commit secrets, machine-specific absolute
paths, or personal information; contributors use their own git author
identity. Keep executables thin — logic belongs in `Packages/EnsoCore` where
tests can reach it. Match the existing comment style: comments explain
constraints and hardware facts the code can't show, not what the next line
does.
