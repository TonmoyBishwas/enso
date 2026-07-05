import Foundation
import os
import EnsoShared
import EnsoEngine
import EnsoSMC
import EnsoBattery

let ENSO_DAEMON_VERSION = ENSO_VERSION

/// The daemon's core: owns the engine, the SMC, and all state. Every entry
/// point (timer tick, power event, XPC call) funnels through `queue`.
final class Daemon {
    static let tickInterval: TimeInterval = 10
    static let preSleepSuppression: TimeInterval = 60
    static let postWakeSettle: TimeInterval = 45

    let queue = DispatchQueue(label: "com.enso.daemon.core")
    let log = Logger(subsystem: "com.enso.daemon", category: "core")

    private let store: DaemonStore
    private let control: ChargingControl
    private let battery: BatteryReader
    private let dryRun: Bool

    private(set) var config: EnsoConfig
    private var memory: EngineMemory
    private var smcErrorStreak = 0
    private var lastAppliedAction: ChargeAction?
    private var lastAppliedLED: LEDState?
    private var lastTickAt: Date?

    private var phase: SystemPhase = .normal
    private var suppressTicksUntil: Date?
    private var settleUntil: Date?

    private var timer: DispatchSourceTimer?
    private var powerEvents: PowerEvents?
    private let sleepAssertion = SleepAssertion()
    private var sleepBlockActive = false

    init(dryRun: Bool) {
        self.dryRun = dryRun
        self.store = DaemonStore()
        self.battery = BatteryReader()
        self.config = store.loadConfig()
        self.memory = store.loadMemory()

        let smc: SMCService
        do {
            let real = try SMCConnection()
            if dryRun {
                let logger = Logger(subsystem: "com.enso.daemon", category: "dry-run")
                smc = DryRunSMC(wrapping: real) { logger.notice("\($0, privacy: .public)") }
            } else {
                smc = real
            }
        } catch {
            fatalError("cannot open AppleSMC: \(error)")
        }
        self.control = ChargingControl(smc: smc)
        log.notice("ensod \(ENSO_DAEMON_VERSION, privacy: .public) starting, strategy=\(self.control.capabilities.strategy.rawValue, privacy: .public) dryRun=\(dryRun)")
    }

    // MARK: lifecycle

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: Self.tickInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        powerEvents = PowerEvents { [weak self] event in
            self?.handlePowerEvent(event)
        }
        if powerEvents == nil {
            log.error("IORegisterForSystemPower failed — sleep handling disabled")
        }
    }

    /// SIGTERM / uninstall path: put the hardware back to stock.
    func shutdown() {
        queue.sync {
            if config.restoreOnExit {
                log.notice("restoring SMC defaults on exit")
                control.restoreDefaults()
            }
            sleepAssertion.release()
            store.save(memory: memory)
        }
    }

    // MARK: tick

    private func tick(forced: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = Date()

        if let until = suppressTicksUntil, now < until, !forced {
            return
        }
        suppressTicksUntil = nil

        if let until = settleUntil {
            if now >= until {
                settleUntil = nil
                phase = .normal
                control.reprobe()
                log.notice("post-wake settle over; strategy=\(self.control.capabilities.strategy.rawValue, privacy: .public)")
            } else {
                phase = .postWakeSettling
            }
        }

        guard let snapshot = try? battery.snapshot(now: now) else {
            log.error("battery snapshot failed")
            return
        }

        let soc: Int
        if config.useHardwarePercentage, let hw = control.hardwareSoC() {
            soc = hw
        } else {
            soc = snapshot.socPercent
        }
        let temp = control.batteryTemperature() ?? snapshot.temperatureCelsius

        let input = EngineInput(
            soc: soc,
            isAdapterConnected: snapshot.isAdapterConnected,
            isCharging: snapshot.isCharging,
            batteryTempCelsius: temp,
            now: now,
            phase: phase,
            config: config,
            hasWorkingInhibitKey: control.capabilities.strategy != .none,
            smcErrorStreak: smcErrorStreak
        )

        let before = memory
        let output = ChargingStateMachine.step(input: input, memory: &memory)

        for event in output.events {
            log.notice("engine event: \(String(describing: event), privacy: .public)")
        }

        // postWakeSettling means: decide nothing new, write nothing.
        if phase != .postWakeSettling {
            apply(output: output, soc: soc)
        }

        if memory != before {
            store.save(memory: memory)
        }
        lastTickAt = now
    }

    private func apply(output: EngineOutput, soc: Int) {
        // Skip the SMC round-trip when nothing changed.
        if output.action != lastAppliedAction {
            do {
                try control.apply(output.action)
                smcErrorStreak = 0
                lastAppliedAction = output.action
                log.notice("applied \(output.action.rawValue, privacy: .public) at soc=\(soc)")
            } catch {
                smcErrorStreak += 1
                lastAppliedAction = nil
                log.error("SMC apply failed (streak \(self.smcErrorStreak)): \(String(describing: error), privacy: .public)")
                if smcErrorStreak >= 3 {
                    control.reprobe()
                    log.error("reprobed after error streak; strategy=\(self.control.capabilities.strategy.rawValue, privacy: .public)")
                }
            }
        }

        if output.led != lastAppliedLED {
            let value: MagSafeLEDValue? = switch output.led {
            case .system: MagSafeLEDValue.system
            case .off: MagSafeLEDValue.off
            case .green: MagSafeLEDValue.green
            case .amber: MagSafeLEDValue.amber
            }
            if let value {
                try? control.setMagSafeLED(value)
                lastAppliedLED = output.led
            }
        }

        if output.sleepBlock != sleepBlockActive {
            sleepBlockActive = output.sleepBlock
            if output.sleepBlock {
                sleepAssertion.hold(reason: "Enso charging to limit")
            } else {
                sleepAssertion.release()
            }
        }
    }

    // MARK: power events

    private func handlePowerEvent(_ event: PowerEvents.Event) {
        switch event {
        case .canSleep(let veto, let allow):
            queue.async { [self] in
                if sleepBlockActive {
                    log.notice("vetoing idle sleep (charge cycle active)")
                    veto()
                } else {
                    allow()
                }
            }
        case .willSleep(let acknowledge):
            queue.async { [self] in
                log.notice("system will sleep — running pre-sleep tick")
                phase = .preSleep
                tick(forced: true)
                phase = .normal
                suppressTicksUntil = Date().addingTimeInterval(Self.preSleepSuppression)
                acknowledge()
            }
        case .didWake:
            queue.async { [self] in
                log.notice("system woke")
                suppressTicksUntil = nil
                settleUntil = Date().addingTimeInterval(Self.postWakeSettle)
                phase = .postWakeSettling
            }
        }
    }

    // MARK: XPC entry points (already on any thread; hop to queue)

    func currentStatus() -> DaemonStatus {
        queue.sync {
            DaemonStatus(
                daemonVersion: ENSO_DAEMON_VERSION,
                strategy: DaemonStatus.ChargingStrategy(rawValue: control.capabilities.strategy.rawValue) ?? .none,
                config: config,
                currentAction: (lastAppliedAction ?? memory.lastAction).rawValue,
                activeTask: memory.activeTask?.label,
                failsafeActive: memory.failsafeActive,
                lastTickAt: lastTickAt
            )
        }
    }

    func apply(newConfig: EnsoConfig) -> String? {
        queue.sync {
            config = newConfig.validated()
            store.save(config: config)
            log.notice("config applied: limit=\(self.config.chargeLimit)")
            tick(forced: true)
            return nil
        }
    }

    func run(command: DaemonCommand) -> String? {
        queue.sync {
            switch command {
            case .topUp:
                logEvents(ChargingStateMachine.start(task: .topUp, memory: &memory))
            case .discharge(let target):
                guard target >= ChargeLimits.dischargeFloor && target <= 100 else {
                    return "discharge target must be \(ChargeLimits.dischargeFloor)-100"
                }
                logEvents(ChargingStateMachine.start(task: .discharge(target: target), memory: &memory))
            case .calibrateNow:
                logEvents(ChargingStateMachine.start(task: .calibration(phase: .chargeToFull, holdUntil: nil), memory: &memory))
            case .cancelTask:
                logEvents(ChargingStateMachine.cancelTask(memory: &memory))
            case .appWillQuit:
                if config.quitBehavior == .resetTo100 {
                    log.notice("app quit with resetTo100 — lifting limit")
                    config.chargeLimit = 100
                    store.save(config: config)
                    logEvents(ChargingStateMachine.cancelTask(memory: &memory))
                }
            case .prepareUninstall:
                log.notice("prepare uninstall: restoring defaults")
                config.chargeLimit = 100
                store.save(config: config)
                memory = EngineMemory()
                store.save(memory: memory)
                control.restoreDefaults()
                lastAppliedAction = .allow
                sleepAssertion.release()
                sleepBlockActive = false
                return nil
            }
            store.save(memory: memory)
            tick(forced: true)
            return nil
        }
    }

    private func logEvents(_ events: [EngineEvent]) {
        for event in events {
            log.notice("engine event: \(String(describing: event), privacy: .public)")
        }
    }

    func secret() -> String? {
        store.loadSecret()
    }
}
