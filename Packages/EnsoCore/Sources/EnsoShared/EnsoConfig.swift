import Foundation

/// Bumped whenever the XPC protocol or config schema changes incompatibly.
/// App and daemon exchange this in the handshake; a mismatch triggers the
/// "helper update required" flow.
public let DAEMON_PROTOCOL_VERSION = 1

/// Marketing version, shared by app, daemon and CLI (built from one commit).
public let ENSO_VERSION = "0.2.0"

public enum ChargeLimits {
    /// Users may never set a limit below this — deep discharge holds are unsafe.
    public static let minimum = 50
    public static let maximum = 100
    /// Discharge tasks refuse to drain below this.
    public static let dischargeFloor = 15
    /// Below this state of charge the engine unconditionally allows charging.
    public static let failsafeSoC = 10

    public static func clamp(_ value: Int) -> Int {
        min(maximum, max(minimum, value))
    }
}

public enum MagSafeLEDMode: String, Codable, Sendable, CaseIterable {
    /// Leave the LED to macOS.
    case system
    /// Enso drives it: green at limit, amber while charging/discharging.
    case enso
    /// Always off.
    case off
}

public enum QuitBehavior: String, Codable, Sendable, CaseIterable {
    /// Daemon keeps enforcing the limit after the app quits (default).
    case keepLimiting
    /// Daemon resets the limit to 100% when the app quits gracefully.
    case resetTo100
}

/// The single versioned configuration document. The app edits it, the daemon
/// owns the persisted copy and re-validates every field on receipt.
public struct EnsoConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int

    /// Upper charge bound, 50...100. 100 disables limiting.
    public var chargeLimit: Int
    /// Sailing mode: allow SoC to drift down to `sailingLowerLimit` before
    /// recharging. Disabled -> hysteresis band is (chargeLimit - 1).
    public var sailingEnabled: Bool
    public var sailingLowerLimit: Int

    /// Automatically force-discharge down to the limit when above it on AC.
    public var automaticDischarge: Bool

    /// Pause charging above this battery temperature (°C).
    public var heatProtectionEnabled: Bool
    public var heatThresholdCelsius: Double

    /// Proactively inhibit charging just before sleep so the battery doesn't
    /// creep to 100% overnight.
    public var stopChargingWhenSleeping: Bool
    /// Hold an IOPM assertion / veto idle sleep while still charging to the
    /// limit on AC.
    public var preventSleepUntilLimit: Bool

    public var magSafeLED: MagSafeLEDMode
    public var quitBehavior: QuitBehavior
    /// Restore charging (allow) when the daemon exits/SIGTERMs.
    public var restoreOnExit: Bool
    /// Defer to Apple's native charge limit (macOS 26.4+) instead of Enso's.
    public var deferToNativeLimit: Bool
    /// Show/use the hardware BMS percentage rather than the macOS-smoothed one.
    public var useHardwarePercentage: Bool

    public init(
        schemaVersion: Int = 1,
        chargeLimit: Int = 80,
        sailingEnabled: Bool = false,
        sailingLowerLimit: Int = 75,
        automaticDischarge: Bool = false,
        heatProtectionEnabled: Bool = false,
        heatThresholdCelsius: Double = 35,
        stopChargingWhenSleeping: Bool = true,
        preventSleepUntilLimit: Bool = false,
        magSafeLED: MagSafeLEDMode = .system,
        quitBehavior: QuitBehavior = .keepLimiting,
        restoreOnExit: Bool = true,
        deferToNativeLimit: Bool = false,
        useHardwarePercentage: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.chargeLimit = chargeLimit
        self.sailingEnabled = sailingEnabled
        self.sailingLowerLimit = sailingLowerLimit
        self.automaticDischarge = automaticDischarge
        self.heatProtectionEnabled = heatProtectionEnabled
        self.heatThresholdCelsius = heatThresholdCelsius
        self.stopChargingWhenSleeping = stopChargingWhenSleeping
        self.preventSleepUntilLimit = preventSleepUntilLimit
        self.magSafeLED = magSafeLED
        self.quitBehavior = quitBehavior
        self.restoreOnExit = restoreOnExit
        self.deferToNativeLimit = deferToNativeLimit
        self.useHardwarePercentage = useHardwarePercentage
    }

    /// Returns a copy with every field forced into its legal range.
    /// The daemon applies this to anything arriving over XPC — the UI clamping
    /// is a convenience, this is the guarantee.
    public func validated() -> EnsoConfig {
        var c = self
        c.chargeLimit = ChargeLimits.clamp(c.chargeLimit)
        // Sailing band must sit below the limit but stay in the legal range.
        c.sailingLowerLimit = min(max(ChargeLimits.minimum, c.sailingLowerLimit), max(ChargeLimits.minimum, c.chargeLimit - 1))
        c.heatThresholdCelsius = min(45, max(30, c.heatThresholdCelsius))
        return c
    }
}
