import Foundation
import EnsoShared

// The charging engine is a pure function: no IOKit, no timers, no wall clock.
// Everything it needs arrives in `EngineInput`, everything it decides leaves
// in `EngineOutput`, and everything it must remember between ticks lives in
// `EngineMemory` (Codable, persisted by the daemon so a crash resumes cleanly).

public enum SystemPhase: Equatable, Sendable {
    case normal
    /// Between kIOMessageSystemWillSleep and actual sleep.
    case preSleep
    /// First ~30s after wake — hold previous action, write nothing new.
    case postWakeSettling
}

public enum CalibrationPhase: String, Codable, Equatable, Sendable {
    case chargeToFull
    case holdFull
    case dischargeToFloor
    case rechargeToFull
    case finalHold
}

public enum EngineTask: Codable, Equatable, Sendable {
    case topUp
    case discharge(target: Int)
    case calibration(phase: CalibrationPhase, holdUntil: Date?)

    public var label: String {
        switch self {
        case .topUp: return "topUp"
        case .discharge: return "discharge"
        case .calibration(let phase, _): return "calibration:\(phase.rawValue)"
        }
    }
}

public enum EngineEvent: Equatable, Sendable {
    case failsafeActivated
    case limitReached
    case topUpDone
    case dischargeDone
    case heatPauseStarted
    case heatPauseEnded
    case calibrationPhaseChanged(CalibrationPhase)
    case calibrationDone
    case taskCancelled(String)
}

public struct EngineInput: Sendable {
    /// State of charge in percent, whichever source the config selects.
    public var soc: Int
    public var isAdapterConnected: Bool
    public var isCharging: Bool
    /// Hottest battery temperature sensor, °C. nil if unavailable.
    public var batteryTempCelsius: Double?
    public var now: Date
    public var phase: SystemPhase
    public var config: EnsoConfig
    /// False when capability probing found no working inhibit key.
    public var hasWorkingInhibitKey: Bool
    /// Consecutive SMC write-verify failures reported by the daemon.
    public var smcErrorStreak: Int

    public init(
        soc: Int,
        isAdapterConnected: Bool,
        isCharging: Bool,
        batteryTempCelsius: Double? = nil,
        now: Date,
        phase: SystemPhase = .normal,
        config: EnsoConfig,
        hasWorkingInhibitKey: Bool = true,
        smcErrorStreak: Int = 0
    ) {
        self.soc = soc
        self.isAdapterConnected = isAdapterConnected
        self.isCharging = isCharging
        self.batteryTempCelsius = batteryTempCelsius
        self.now = now
        self.phase = phase
        self.config = config
        self.hasWorkingInhibitKey = hasWorkingInhibitKey
        self.smcErrorStreak = smcErrorStreak
    }
}

public struct EngineMemory: Codable, Equatable, Sendable {
    public var lastAction: ChargeAction
    public var activeTask: EngineTask?
    public var heatLatched: Bool
    public var heatCooldownUntil: Date?
    /// Set when a top-up first observes SoC >= 99; completes after 10 min there.
    public var topUpNearFullSince: Date?
    public var failsafeActive: Bool
    /// Consecutive ticks the adapter has read as disconnected. IOKit reports
    /// the adapter as gone for a while after wake, so unplug handling waits
    /// for two readings in a row.
    public var adapterGoneStreak: Int

    public init() {
        lastAction = .allow
        activeTask = nil
        heatLatched = false
        heatCooldownUntil = nil
        topUpNearFullSince = nil
        failsafeActive = false
        adapterGoneStreak = 0
    }

    private enum CodingKeys: String, CodingKey {
        case lastAction, activeTask, heatLatched, heatCooldownUntil,
             topUpNearFullSince, failsafeActive, adapterGoneStreak
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastAction = try c.decode(ChargeAction.self, forKey: .lastAction)
        activeTask = try c.decodeIfPresent(EngineTask.self, forKey: .activeTask)
        heatLatched = try c.decode(Bool.self, forKey: .heatLatched)
        heatCooldownUntil = try c.decodeIfPresent(Date.self, forKey: .heatCooldownUntil)
        topUpNearFullSince = try c.decodeIfPresent(Date.self, forKey: .topUpNearFullSince)
        failsafeActive = try c.decode(Bool.self, forKey: .failsafeActive)
        adapterGoneStreak = try c.decodeIfPresent(Int.self, forKey: .adapterGoneStreak) ?? 0
    }
}

public struct EngineOutput: Equatable, Sendable {
    public var action: ChargeAction
    /// Hold a prevent-sleep assertion / veto idle sleep this tick.
    public var sleepBlock: Bool
    public var led: LEDState
    public var events: [EngineEvent]
}

public enum EngineConstants {
    public static let heatCooldown: TimeInterval = 5 * 60
    /// Resume charging only once temp has fallen this far below the threshold.
    public static let heatHysteresisCelsius: Double = 2
    public static let calibrationHold: TimeInterval = 60 * 60
    public static let topUpNearFullWindow: TimeInterval = 10 * 60
}

public enum ChargingStateMachine {

    public static func step(input: EngineInput, memory: inout EngineMemory) -> EngineOutput {
        var events: [EngineEvent] = []
        let config = input.config.validated()
        let limit = config.chargeLimit

        // P0 — failsafe. Nothing may override this.
        if input.soc <= ChargeLimits.failsafeSoC || !input.hasWorkingInhibitKey || input.smcErrorStreak >= 3 {
            if !memory.failsafeActive {
                events.append(.failsafeActivated)
                if let task = memory.activeTask {
                    events.append(.taskCancelled("failsafe cancelled \(task.label)"))
                }
            }
            memory.failsafeActive = true
            memory.activeTask = nil
            memory.topUpNearFullSince = nil
            return finish(.allow, input: input, memory: &memory, config: config, events: events)
        }
        if memory.failsafeActive {
            // Condition cleared (daemon re-probed successfully / SoC recovered).
            memory.failsafeActive = false
        }

        // Post-wake settle comes before any adapter-based decision: IOKit's
        // adapter/battery readings are stale for a while after wake, and one
        // stale "unplugged" reading must not cancel tasks (seen on hardware).
        if input.phase == .postWakeSettling {
            return EngineOutput(action: memory.lastAction, sleepBlock: false,
                                led: led(for: memory.lastAction, input: input, config: config, atLimit: input.soc >= limit),
                                events: events)
        }

        // Adapter-gone debounce (see EngineMemory.adapterGoneStreak).
        if input.isAdapterConnected {
            memory.adapterGoneStreak = 0
        } else {
            memory.adapterGoneStreak += 1
        }

        // P1 — no adapter: never hold a stale inhibit, and AC-dependent
        // one-shot tasks end here (calibration merely pauses).
        // Caveats: force-discharge works by disabling the adapter in
        // firmware, so while we are the ones discharging, an "unplugged"
        // reading is our own doing — not a physical unplug. And a single
        // "unplugged" reading can be post-wake staleness, so require two.
        let dischargingByUs = memory.lastAction == .forceDischarge
        if memory.adapterGoneStreak >= 2 && !dischargingByUs {
            switch memory.activeTask {
            case .topUp:
                memory.activeTask = nil
                memory.topUpNearFullSince = nil
                events.append(.taskCancelled("top up cancelled: adapter unplugged"))
            case .discharge:
                memory.activeTask = nil
                events.append(.taskCancelled("discharge cancelled: adapter unplugged"))
            default:
                break
            }
            return finish(.allow, input: input, memory: &memory, config: config, events: events)
        }

        // P2 — pre-sleep transition (postWakeSettling was handled above).
        if input.phase == .preSleep {
            if config.stopChargingWhenSleeping && effectiveTarget(config: config, memory: memory) < 100 {
                return finish(.inhibit, input: input, memory: &memory, config: config, events: events)
            }
            return finish(memory.lastAction == .forceDischarge ? .inhibit : memory.lastAction,
                          input: input, memory: &memory, config: config, events: events)
        }

        // P3 — heat protection (inhibit only; never discharge a hot battery).
        if config.heatProtectionEnabled, let temp = input.batteryTempCelsius {
            if memory.heatLatched {
                let cooledEnough = temp < config.heatThresholdCelsius - EngineConstants.heatHysteresisCelsius
                let cooldownOver = memory.heatCooldownUntil.map { input.now >= $0 } ?? true
                if cooledEnough && cooldownOver {
                    memory.heatLatched = false
                    memory.heatCooldownUntil = nil
                    events.append(.heatPauseEnded)
                } else {
                    return finish(.inhibit, input: input, memory: &memory, config: config, events: events)
                }
            } else if temp >= config.heatThresholdCelsius {
                memory.heatLatched = true
                memory.heatCooldownUntil = input.now.addingTimeInterval(EngineConstants.heatCooldown)
                events.append(.heatPauseStarted)
                return finish(.inhibit, input: input, memory: &memory, config: config, events: events)
            }
        }

        // P4 — calibration sub-machine.
        if case .calibration(let phase, let holdUntil) = memory.activeTask {
            let (action, newPhase, newHold, phaseEvents, done) =
                calibrationStep(phase: phase, holdUntil: holdUntil, input: input)
            events.append(contentsOf: phaseEvents)
            if done {
                memory.activeTask = nil
                events.append(.calibrationDone)
                // fall through to maintain
            } else {
                memory.activeTask = .calibration(phase: newPhase, holdUntil: newHold)
                return finish(action, input: input, memory: &memory, config: config, events: events)
            }
        }

        // P5 — top up.
        if case .topUp = memory.activeTask {
            let nearFullLongEnough: Bool
            if input.soc >= 99 {
                let since = memory.topUpNearFullSince ?? input.now
                if memory.topUpNearFullSince == nil { memory.topUpNearFullSince = input.now }
                nearFullLongEnough = input.now.timeIntervalSince(since) >= EngineConstants.topUpNearFullWindow
            } else {
                memory.topUpNearFullSince = nil
                nearFullLongEnough = false
            }
            if input.soc >= 100 || nearFullLongEnough {
                memory.activeTask = nil
                memory.topUpNearFullSince = nil
                events.append(.topUpDone)
                // fall through to maintain
            } else {
                return finish(.allow, input: input, memory: &memory, config: config, events: events)
            }
        }

        // P6 — discharge task.
        if case .discharge(let target) = memory.activeTask {
            let floor = max(target, ChargeLimits.dischargeFloor)
            if input.soc <= floor {
                memory.activeTask = nil
                events.append(.dischargeDone)
                // fall through to maintain
            } else {
                return finish(.forceDischarge, input: input, memory: &memory, config: config, events: events)
            }
        }

        // P7 — maintain (plain limit or sailing band) with hysteresis.
        if limit >= 100 {
            return finish(.allow, input: input, memory: &memory, config: config, events: events)
        }
        let lower = config.sailingEnabled ? config.sailingLowerLimit : limit - 1
        let action: ChargeAction
        if input.soc > limit && config.automaticDischarge {
            action = .forceDischarge
        } else if input.soc >= limit {
            if memory.lastAction != .inhibit {
                events.append(.limitReached)
            }
            action = .inhibit
        } else if input.soc <= lower {
            action = .allow
        } else {
            // Inside the hysteresis band: keep the latched maintain action.
            // A latched forceDischarge (from an ended task) maps to inhibit —
            // we're above `lower`, so holding is the conservative choice.
            action = memory.lastAction == .allow ? .allow : .inhibit
        }
        return finish(action, input: input, memory: &memory, config: config, events: events)
    }

    // MARK: - Helpers

    private static func calibrationStep(
        phase: CalibrationPhase,
        holdUntil: Date?,
        input: EngineInput
    ) -> (ChargeAction, CalibrationPhase, Date?, [EngineEvent], Bool) {
        switch phase {
        case .chargeToFull:
            if input.soc >= 100 {
                let hold = input.now.addingTimeInterval(EngineConstants.calibrationHold)
                return (.inhibit, .holdFull, hold, [.calibrationPhaseChanged(.holdFull)], false)
            }
            return (.allow, phase, nil, [], false)
        case .holdFull:
            if let until = holdUntil, input.now >= until {
                return (.forceDischarge, .dischargeToFloor, nil, [.calibrationPhaseChanged(.dischargeToFloor)], false)
            }
            return (.inhibit, phase, holdUntil, [], false)
        case .dischargeToFloor:
            if input.soc <= ChargeLimits.dischargeFloor {
                return (.allow, .rechargeToFull, nil, [.calibrationPhaseChanged(.rechargeToFull)], false)
            }
            return (.forceDischarge, phase, nil, [], false)
        case .rechargeToFull:
            if input.soc >= 100 {
                let hold = input.now.addingTimeInterval(EngineConstants.calibrationHold)
                return (.inhibit, .finalHold, hold, [.calibrationPhaseChanged(.finalHold)], false)
            }
            return (.allow, phase, nil, [], false)
        case .finalHold:
            if let until = holdUntil, input.now >= until {
                return (.allow, phase, holdUntil, [], true)
            }
            return (.inhibit, phase, holdUntil, [], false)
        }
    }

    /// The SoC the current mode is trying to reach (used for sleep-block).
    private static func effectiveTarget(config: EnsoConfig, memory: EngineMemory) -> Int {
        switch memory.activeTask {
        case .topUp, .calibration: return 100
        case .discharge(let target): return target
        case nil: return config.chargeLimit
        }
    }

    private static func finish(
        _ action: ChargeAction,
        input: EngineInput,
        memory: inout EngineMemory,
        config: EnsoConfig,
        events: [EngineEvent]
    ) -> EngineOutput {
        memory.lastAction = action

        // Sleep-block: any active AC task must keep the Mac awake to run;
        // otherwise only when the user opted into prevent-sleep-until-limit
        // and we're still below target on AC. A force-discharge makes the
        // adapter read as disconnected — treat it as present.
        let adapterPresent = input.isAdapterConnected || action == .forceDischarge
        let sleepBlock: Bool
        if !adapterPresent || input.phase != .normal || memory.failsafeActive {
            sleepBlock = false
        } else if memory.activeTask != nil {
            sleepBlock = true
        } else {
            sleepBlock = config.preventSleepUntilLimit && input.soc < config.chargeLimit && action == .allow
        }

        return EngineOutput(
            action: action,
            sleepBlock: sleepBlock,
            led: led(for: action, input: input, config: config, atLimit: input.soc >= config.chargeLimit),
            events: events
        )
    }

    private static func led(for action: ChargeAction, input: EngineInput, config: EnsoConfig, atLimit: Bool) -> LEDState {
        switch config.magSafeLED {
        case .system: return .system
        case .off: return .off
        case .enso:
            guard input.isAdapterConnected || action == .forceDischarge else { return .system }
            switch action {
            case .forceDischarge: return .amber
            case .inhibit: return atLimit ? .green : .amber
            case .allow: return input.isCharging ? .amber : (atLimit ? .green : .amber)
            }
        }
    }

    // MARK: - Task control (called by the daemon on user commands)

    /// Starts a task, cancelling any previous one (last writer wins).
    public static func start(task: EngineTask, memory: inout EngineMemory) -> [EngineEvent] {
        var events: [EngineEvent] = []
        if let old = memory.activeTask {
            events.append(.taskCancelled("\(old.label) cancelled by \(task.label)"))
        }
        switch task {
        case .calibration:
            memory.activeTask = .calibration(phase: .chargeToFull, holdUntil: nil)
            events.append(.calibrationPhaseChanged(.chargeToFull))
        case .discharge(let target):
            memory.activeTask = .discharge(target: max(target, ChargeLimits.dischargeFloor))
        case .topUp:
            memory.activeTask = .topUp
        }
        memory.topUpNearFullSince = nil
        return events
    }

    public static func cancelTask(memory: inout EngineMemory) -> [EngineEvent] {
        guard let task = memory.activeTask else { return [] }
        memory.activeTask = nil
        memory.topUpNearFullSince = nil
        return [.taskCancelled("\(task.label) cancelled by user")]
    }
}
