import XCTest
@testable import EnsoEngine
import EnsoShared

/// Property tests: drive the engine against a crude battery simulation for
/// thousands of ticks with a deterministic PRNG and assert the safety
/// invariants that must never break.
final class SimulatedBatteryPropertyTests: XCTestCase {

    struct XorshiftRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// One simulated tick = 10s. Charging ~ +0.5%/tick, discharging ~ -0.5%.
    func runSimulation(config: EnsoConfig, seed: UInt64, ticks: Int, startSoC: Int) -> (maxSoC: Int, minSoC: Int, violations: [String]) {
        var rng = XorshiftRNG(state: seed)
        var mem = EngineMemory()
        var soc = Double(startSoC)
        var adapter = true
        var violations: [String] = []
        var maxSoC = startSoC, minSoC = startSoC
        var settled = false
        var unpluggedTicks = 0
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)

        for tick in 0..<ticks {
            // Occasionally yank/restore the adapter.
            if Double.random(in: 0..<1, using: &rng) < 0.005 { adapter.toggle() }
            unpluggedTicks = adapter ? 0 : unpluggedTicks + 1

            let input = EngineInput(
                soc: Int(soc.rounded()),
                isAdapterConnected: adapter,
                isCharging: adapter,
                batteryTempCelsius: 30,
                now: t0.addingTimeInterval(Double(tick) * 10),
                phase: .normal,
                config: config
            )
            let out = ChargingStateMachine.step(input: input, memory: &mem)

            // Invariant: never inhibit or discharge at/below the failsafe SoC.
            if Int(soc.rounded()) <= ChargeLimits.failsafeSoC && out.action != .allow {
                violations.append("tick \(tick): action \(out.action) at SoC \(soc)")
            }
            // Invariant: no inhibit action retained without adapter
            // (one tick of debounce grace is by design).
            if unpluggedTicks >= 2 && out.action != .allow {
                violations.append("tick \(tick): \(out.action) while unplugged")
            }

            // Battery physics.
            switch out.action {
            case .allow where adapter && soc < 100: soc += Double.random(in: 0.3...0.5, using: &rng)
            case .forceDischarge where adapter: soc -= Double.random(in: 0.3...0.5, using: &rng)
            case .inhibit: soc -= Double.random(in: 0...0.02, using: &rng) // trickle self-drain
            default:
                if !adapter { soc -= Double.random(in: 0.1...0.3, using: &rng) }
            }
            soc = min(100, max(0, soc))

            // Give the sim time to reach the limit before enforcing steady state.
            if tick > ticks / 4 { settled = true }
            if settled && adapter {
                maxSoC = max(maxSoC, Int(soc.rounded()))
            }
            minSoC = min(minSoC, Int(soc.rounded()))
        }
        return (maxSoC, minSoC, violations)
    }

    func testSteadyStateNeverExceedsLimitPlusTwo() {
        for seed: UInt64 in [1, 42, 987_654_321] {
            var config = EnsoConfig()
            config.chargeLimit = 80
            let result = runSimulation(config: config, seed: seed, ticks: 5000, startSoC: 60)
            XCTAssertLessThanOrEqual(result.maxSoC, 82, "seed \(seed)")
            XCTAssertTrue(result.violations.isEmpty, "seed \(seed): \(result.violations)")
        }
    }

    func testSailingStaysInsideBand() {
        var config = EnsoConfig()
        config.chargeLimit = 80
        config.sailingEnabled = true
        config.sailingLowerLimit = 70
        let result = runSimulation(config: config, seed: 7, ticks: 5000, startSoC: 75)
        XCTAssertLessThanOrEqual(result.maxSoC, 82)
        XCTAssertTrue(result.violations.isEmpty, "\(result.violations)")
    }

    func testDischargeNeverBreachesFloor() {
        var config = EnsoConfig()
        config.chargeLimit = 80
        var mem = EngineMemory()
        _ = ChargingStateMachine.start(task: .discharge(target: 15), memory: &mem)
        var soc = 40.0
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        for tick in 0..<2000 {
            let input = EngineInput(
                soc: Int(soc.rounded()), isAdapterConnected: true, isCharging: false,
                now: t0.addingTimeInterval(Double(tick) * 10), config: config
            )
            let out = ChargingStateMachine.step(input: input, memory: &mem)
            if out.action == .forceDischarge {
                XCTAssertGreaterThan(Int(soc.rounded()), ChargeLimits.dischargeFloor - 1,
                                     "discharging at SoC \(soc)")
                soc -= 0.4
            } else if Int(soc.rounded()) <= ChargeLimits.dischargeFloor {
                break // task completed at the floor — correct
            }
        }
        XCTAssertNil(mem.activeTask)
        XCTAssertGreaterThanOrEqual(Int(soc.rounded()), ChargeLimits.dischargeFloor - 1)
    }
}
