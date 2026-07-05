import XCTest
@testable import EnsoEngine
import EnsoShared

final class ChargingStateMachineTests: XCTestCase {

    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func input(
        soc: Int,
        adapter: Bool = true,
        charging: Bool = true,
        temp: Double? = nil,
        at: TimeInterval = 0,
        phase: SystemPhase = .normal,
        config: EnsoConfig = EnsoConfig(),
        hasKey: Bool = true,
        errorStreak: Int = 0
    ) -> EngineInput {
        EngineInput(
            soc: soc, isAdapterConnected: adapter, isCharging: charging,
            batteryTempCelsius: temp, now: t0.addingTimeInterval(at), phase: phase,
            config: config, hasWorkingInhibitKey: hasKey, smcErrorStreak: errorStreak
        )
    }

    // MARK: P7 maintain

    func testChargesBelowLimitAndInhibitsAtLimit() {
        var mem = EngineMemory()
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 60), memory: &mem).action, .allow)
        let out = ChargingStateMachine.step(input: input(soc: 80), memory: &mem)
        XCTAssertEqual(out.action, .inhibit)
        XCTAssertTrue(out.events.contains(.limitReached))
    }

    func testHysteresisHoldsInsideBand() {
        var mem = EngineMemory()
        _ = ChargingStateMachine.step(input: input(soc: 80), memory: &mem) // latch inhibit
        // 79 is inside the band (lower = 79 for limit 80): stays inhibited? No:
        // lower = limit - 1 = 79, soc <= lower → allow. Band is empty for plain limit.
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 79), memory: &mem).action, .allow)
    }

    func testSailingBandKeepsLatchedAction() {
        var config = EnsoConfig(sailingEnabled: true, sailingLowerLimit: 75)
        config.chargeLimit = 80
        var mem = EngineMemory()
        _ = ChargingStateMachine.step(input: input(soc: 80, config: config), memory: &mem)
        // Drifting down inside the band: stay inhibited (sail down).
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 78, config: config), memory: &mem).action, .inhibit)
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 76, config: config), memory: &mem).action, .inhibit)
        // Hit the lower bound: recharge.
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 75, config: config), memory: &mem).action, .allow)
        // Climbing back inside the band: keep charging.
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 78, config: config), memory: &mem).action, .allow)
    }

    func testLimit100NeverInhibits() {
        var config = EnsoConfig(); config.chargeLimit = 100
        var mem = EngineMemory()
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 100, config: config), memory: &mem).action, .allow)
    }

    func testAutomaticDischargeDrainsAboveLimit() {
        var config = EnsoConfig(); config.automaticDischarge = true
        var mem = EngineMemory()
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 95, config: config), memory: &mem).action, .forceDischarge)
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 80, config: config), memory: &mem).action, .inhibit)
    }

    // MARK: P0 failsafe

    func testFailsafeAtLowSoC() {
        var mem = EngineMemory()
        mem.activeTask = .discharge(target: 15)
        let out = ChargingStateMachine.step(input: input(soc: 10), memory: &mem)
        XCTAssertEqual(out.action, .allow)
        XCTAssertTrue(out.events.contains(.failsafeActivated))
        XCTAssertNil(mem.activeTask)
    }

    func testFailsafeOnMissingKeyAndErrorStreak() {
        var mem = EngineMemory()
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 90, hasKey: false), memory: &mem).action, .allow)
        var mem2 = EngineMemory()
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 90, errorStreak: 3), memory: &mem2).action, .allow)
    }

    func testFailsafeClearsWhenConditionGone() {
        var mem = EngineMemory()
        _ = ChargingStateMachine.step(input: input(soc: 8), memory: &mem)
        XCTAssertTrue(mem.failsafeActive)
        let out = ChargingStateMachine.step(input: input(soc: 60), memory: &mem)
        XCTAssertFalse(mem.failsafeActive)
        XCTAssertEqual(out.action, .allow)
    }

    // MARK: P1 adapter

    func testUnplugAllowsAndCancelsTopUp() {
        var mem = EngineMemory()
        mem.activeTask = .topUp
        let out = ChargingStateMachine.step(input: input(soc: 90, adapter: false, charging: false), memory: &mem)
        XCTAssertEqual(out.action, .allow)
        XCTAssertNil(mem.activeTask)
        XCTAssertTrue(out.events.contains { if case .taskCancelled = $0 { return true }; return false })
    }

    func testUnplugPausesCalibrationWithoutCancelling() {
        var mem = EngineMemory()
        mem.activeTask = .calibration(phase: .chargeToFull, holdUntil: nil)
        let out = ChargingStateMachine.step(input: input(soc: 50, adapter: false, charging: false), memory: &mem)
        XCTAssertEqual(out.action, .allow)
        XCTAssertNotNil(mem.activeTask)
        XCTAssertTrue(out.events.isEmpty)
    }

    // MARK: P2 sleep

    func testPreSleepInhibitsWhenLimited() {
        var mem = EngineMemory()
        let out = ChargingStateMachine.step(input: input(soc: 60, phase: .preSleep), memory: &mem)
        XCTAssertEqual(out.action, .inhibit) // even below limit: don't creep overnight
    }

    func testPreSleepRespectsDisabledStopChargingWhenSleeping() {
        var config = EnsoConfig(); config.stopChargingWhenSleeping = false
        var mem = EngineMemory()
        mem.lastAction = .allow
        let out = ChargingStateMachine.step(input: input(soc: 60, phase: .preSleep, config: config), memory: &mem)
        XCTAssertEqual(out.action, .allow)
    }

    func testPostWakeSettleHoldsPreviousAction() {
        var mem = EngineMemory()
        _ = ChargingStateMachine.step(input: input(soc: 80), memory: &mem) // inhibit
        let out = ChargingStateMachine.step(input: input(soc: 75, phase: .postWakeSettling), memory: &mem)
        XCTAssertEqual(out.action, .inhibit) // held, not recomputed
    }

    // MARK: P3 heat

    func testHeatProtectionLatchesAndCoolsDown() {
        var config = EnsoConfig(); config.heatProtectionEnabled = true; config.heatThresholdCelsius = 35
        var mem = EngineMemory()
        let hot = ChargingStateMachine.step(input: input(soc: 60, temp: 36, config: config), memory: &mem)
        XCTAssertEqual(hot.action, .inhibit)
        XCTAssertTrue(hot.events.contains(.heatPauseStarted))
        // Cooled but before the 5-minute cooldown: still paused.
        let early = ChargingStateMachine.step(input: input(soc: 60, temp: 30, at: 60, config: config), memory: &mem)
        XCTAssertEqual(early.action, .inhibit)
        // Cooled below threshold-2 AND cooldown elapsed: resumes.
        let resumed = ChargingStateMachine.step(input: input(soc: 60, temp: 32.9, at: 301, config: config), memory: &mem)
        XCTAssertEqual(resumed.action, .allow)
        XCTAssertTrue(resumed.events.contains(.heatPauseEnded))
    }

    func testHeatNotResumedIfStillWarm() {
        var config = EnsoConfig(); config.heatProtectionEnabled = true; config.heatThresholdCelsius = 35
        var mem = EngineMemory()
        _ = ChargingStateMachine.step(input: input(soc: 60, temp: 36, config: config), memory: &mem)
        // Cooldown elapsed but temp only just below threshold (hysteresis says wait).
        let out = ChargingStateMachine.step(input: input(soc: 60, temp: 34, at: 600, config: config), memory: &mem)
        XCTAssertEqual(out.action, .inhibit)
    }

    // MARK: P4 calibration

    func testCalibrationFullCycle() {
        var mem = EngineMemory()
        _ = ChargingStateMachine.start(task: .calibration(phase: .chargeToFull, holdUntil: nil), memory: &mem)

        // Charge up.
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 82), memory: &mem).action, .allow)
        // Reach 100: hold begins.
        let holdOut = ChargingStateMachine.step(input: input(soc: 100), memory: &mem)
        XCTAssertEqual(holdOut.action, .inhibit)
        XCTAssertTrue(holdOut.events.contains(.calibrationPhaseChanged(.holdFull)))
        // Mid-hold.
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 100, at: 1800), memory: &mem).action, .inhibit)
        // Hold elapsed: discharge leg.
        let dis = ChargingStateMachine.step(input: input(soc: 100, at: 3601), memory: &mem)
        XCTAssertEqual(dis.action, .forceDischarge)
        // Reaches floor: recharge.
        let re = ChargingStateMachine.step(input: input(soc: 15, at: 9000), memory: &mem)
        XCTAssertEqual(re.action, .allow)
        // Back at 100: final hold.
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 100, at: 15000), memory: &mem).action, .inhibit)
        // Final hold elapsed: done, returns to maintain (soc 100 > limit 80 → inhibit).
        let done = ChargingStateMachine.step(input: input(soc: 100, at: 15000 + 3601), memory: &mem)
        XCTAssertTrue(done.events.contains(.calibrationDone))
        XCTAssertNil(mem.activeTask)
        XCTAssertEqual(done.action, .inhibit)
    }

    func testHeatOverridesCalibration() {
        var config = EnsoConfig(); config.heatProtectionEnabled = true; config.heatThresholdCelsius = 35
        var mem = EngineMemory()
        _ = ChargingStateMachine.start(task: .calibration(phase: .chargeToFull, holdUntil: nil), memory: &mem)
        let out = ChargingStateMachine.step(input: input(soc: 60, temp: 40, config: config), memory: &mem)
        XCTAssertEqual(out.action, .inhibit)
        if case .calibration = mem.activeTask {} else { XCTFail("calibration should survive a heat pause") }
    }

    // MARK: P5 top up

    func testTopUpChargesToFullThenReverts() {
        var mem = EngineMemory()
        _ = ChargingStateMachine.start(task: .topUp, memory: &mem)
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 85), memory: &mem).action, .allow)
        let out = ChargingStateMachine.step(input: input(soc: 100), memory: &mem)
        XCTAssertTrue(out.events.contains(.topUpDone))
        XCTAssertEqual(out.action, .inhibit) // maintain takes over at 100 > 80
    }

    func testTopUpCompletesAfterTenMinutesNear99() {
        var mem = EngineMemory()
        _ = ChargingStateMachine.start(task: .topUp, memory: &mem)
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 99, at: 0), memory: &mem).action, .allow)
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 99, at: 300), memory: &mem).action, .allow)
        let out = ChargingStateMachine.step(input: input(soc: 99, at: 601), memory: &mem)
        XCTAssertTrue(out.events.contains(.topUpDone))
    }

    // MARK: P6 discharge

    func testDischargeStopsAtTargetAndRespectsFloor() {
        var mem = EngineMemory()
        _ = ChargingStateMachine.start(task: .discharge(target: 5), memory: &mem) // clamped to 15
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 40), memory: &mem).action, .forceDischarge)
        let out = ChargingStateMachine.step(input: input(soc: 15), memory: &mem)
        XCTAssertTrue(out.events.contains(.dischargeDone))
        XCTAssertNil(mem.activeTask)
    }

    func testStartTaskCancelsPrevious() {
        var mem = EngineMemory()
        _ = ChargingStateMachine.start(task: .calibration(phase: .chargeToFull, holdUntil: nil), memory: &mem)
        let events = ChargingStateMachine.start(task: .topUp, memory: &mem)
        XCTAssertTrue(events.contains { if case .taskCancelled = $0 { return true }; return false })
        XCTAssertEqual(mem.activeTask, .topUp)
    }

    // MARK: sleep-block & LED

    func testSleepBlockWhenChargingTowardLimit() {
        var config = EnsoConfig(); config.preventSleepUntilLimit = true
        var mem = EngineMemory()
        XCTAssertTrue(ChargingStateMachine.step(input: input(soc: 60, config: config), memory: &mem).sleepBlock)
        XCTAssertFalse(ChargingStateMachine.step(input: input(soc: 80, config: config), memory: &mem).sleepBlock)
        XCTAssertFalse(ChargingStateMachine.step(input: input(soc: 60, adapter: false, config: config), memory: &mem).sleepBlock)
    }

    func testLEDGreenAtLimitAmberWhileCharging() {
        var config = EnsoConfig(); config.magSafeLED = .enso
        var mem = EngineMemory()
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 60, config: config), memory: &mem).led, .amber)
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 80, config: config), memory: &mem).led, .green)
        XCTAssertEqual(ChargingStateMachine.step(input: input(soc: 60, adapter: false, config: config), memory: &mem).led, .system)
    }

    // MARK: memory persistence

    func testMemoryRoundTripsThroughJSON() throws {
        var mem = EngineMemory()
        _ = ChargingStateMachine.start(task: .calibration(phase: .chargeToFull, holdUntil: nil), memory: &mem)
        _ = ChargingStateMachine.step(input: input(soc: 100), memory: &mem) // enter holdFull
        let data = try JSONEncoder().encode(mem)
        let restored = try JSONDecoder().decode(EngineMemory.self, from: data)
        XCTAssertEqual(restored, mem)
    }
}
