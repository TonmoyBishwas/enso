import Foundation
import EnsoShared

/// Which SMC key set this machine's firmware speaks.
public enum ChargingStrategy: String, Sendable {
    case tahoe    // CHTE (+ CHIE)
    case legacy   // CH0B + CH0C (+ CH0I)
    case none     // nothing usable — stand down (failsafe)
}

/// Snapshot of what the firmware offers, probed by test-reading keys.
public struct SMCCapabilities: Sendable {
    public var strategy: ChargingStrategy
    public var hasMagSafeLED: Bool
    public var hasAdapterControl: Bool   // CHIE or CH0I present
    public var hasHardwareSoC: Bool      // BUIC
    public var hasBatteryTemp: Bool      // TB0T family
    public var hasNativeLimitFlag: Bool  // CHWA

    public static func probe(_ smc: SMCService) -> SMCCapabilities {
        let strategy: ChargingStrategy
        if smc.keyExists(SMCKeys.chte) {
            strategy = .tahoe
        } else if smc.keyExists(SMCKeys.ch0b) && smc.keyExists(SMCKeys.ch0c) {
            strategy = .legacy
        } else {
            strategy = .none
        }
        let adapterControl = strategy == .tahoe
            ? smc.keyExists(SMCKeys.chie)
            : smc.keyExists(SMCKeys.ch0i)
        return SMCCapabilities(
            strategy: strategy,
            hasMagSafeLED: smc.keyExists(SMCKeys.aclc),
            hasAdapterControl: adapterControl,
            hasHardwareSoC: smc.keyExists(SMCKeys.buic),
            hasBatteryTemp: smc.keyExists(SMCKeys.tb0t),
            hasNativeLimitFlag: smc.keyExists(SMCKeys.chwa)
        )
    }
}

/// Translates engine actions into concrete, verified SMC writes for the
/// strategy this machine supports. All methods are root-only in practice.
public final class ChargingControl {
    private let smc: SMCService
    public private(set) var capabilities: SMCCapabilities

    public init(smc: SMCService) {
        self.smc = smc
        self.capabilities = SMCCapabilities.probe(smc)
    }

    public func reprobe() {
        capabilities = SMCCapabilities.probe(smc)
    }

    /// Applies a ChargeAction. Throws on write/verify failure so the daemon
    /// can track error streaks and eventually fail safe.
    public func apply(_ action: ChargeAction) throws {
        switch action {
        case .allow:
            try setForceDischarge(false)
            try setChargingInhibited(false)
        case .inhibit:
            try setForceDischarge(false)
            try setChargingInhibited(true)
        case .forceDischarge:
            try setChargingInhibited(true)
            try setForceDischarge(true)
        }
    }

    public func setChargingInhibited(_ inhibited: Bool) throws {
        switch capabilities.strategy {
        case .tahoe:
            let value: [UInt8] = inhibited ? [0x01, 0x00, 0x00, 0x00] : [0x00, 0x00, 0x00, 0x00]
            try smc.writeVerified(SMCKeys.chte, value)
        case .legacy:
            let byte: UInt8 = inhibited ? 0x02 : 0x00
            try smc.writeVerified(SMCKeys.ch0b, [byte])
            try smc.writeVerified(SMCKeys.ch0c, [byte])
        case .none:
            throw SMCError.keyNotFound("CHTE/CH0B")
        }
    }

    public func setForceDischarge(_ discharging: Bool) throws {
        guard capabilities.hasAdapterControl else {
            if discharging { throw SMCError.keyNotFound("CHIE/CH0I") }
            return // nothing to clear on machines without the key
        }
        switch capabilities.strategy {
        case .tahoe:
            try smc.writeVerified(SMCKeys.chie, [discharging ? 0x08 : 0x00])
        case .legacy:
            try smc.writeVerified(SMCKeys.ch0i, [discharging ? 0x01 : 0x00])
        case .none:
            throw SMCError.keyNotFound("CHIE/CH0I")
        }
    }

    public func isChargingInhibited() throws -> Bool {
        switch capabilities.strategy {
        case .tahoe:
            return try smc.readBytes(SMCKeys.chte).contains { $0 != 0 }
        case .legacy:
            return try smc.readBytes(SMCKeys.ch0b).contains { $0 != 0 }
        case .none:
            return false
        }
    }

    public func setMagSafeLED(_ led: MagSafeLEDValue) throws {
        guard capabilities.hasMagSafeLED else { return }
        try smc.writeVerified(SMCKeys.aclc, [led.rawValue])
    }

    /// Puts every key Enso may have touched back to stock. Called on
    /// SIGTERM, uninstall, and quit-with-reset. Best-effort by design:
    /// tries every key even if an earlier one fails.
    public func restoreDefaults() {
        try? setForceDischarge(false)
        try? setChargingInhibited(false)
        if capabilities.hasMagSafeLED {
            try? smc.writeBytes(SMCKeys.aclc, [MagSafeLEDValue.system.rawValue])
        }
    }

    // MARK: telemetry (unprivileged)

    public func hardwareSoC() -> Int? {
        guard capabilities.hasHardwareSoC,
              let bytes = try? smc.readBytes(SMCKeys.buic), !bytes.isEmpty else { return nil }
        return Int(bytes[0])
    }

    /// Hottest battery temp sensor in °C. SMC flt/ui16 formats vary by
    /// firmware; TB0T-family report centi-Kelvin-ish ui16 on some models and
    /// IEEE float on others — decode both.
    public func batteryTemperature() -> Double? {
        guard capabilities.hasBatteryTemp else { return nil }
        var best: Double?
        for key in [SMCKeys.tb0t, SMCKeys.tb1t, SMCKeys.tb2t] {
            guard let info = try? smc.keyInfo(key),
                  let bytes = try? smc.readBytes(key) else { continue }
            if let value = Self.decodeTemperature(type: info.type, bytes: bytes) {
                best = max(best ?? -Double.infinity, value)
            }
        }
        return best
    }

    static func decodeTemperature(type: UInt32, bytes: [UInt8]) -> Double? {
        let flt = SMCKey("flt ").code
        let ui16 = SMCKey("ui16").code
        let sp78 = SMCKey("sp78").code
        if type == flt, bytes.count >= 4 {
            let raw = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            let value = Double(Float(bitPattern: raw))
            return (value > -50 && value < 150) ? value : nil
        }
        if type == sp78, bytes.count >= 2 {
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0
        }
        if type == ui16, bytes.count >= 2 {
            // Big-endian hundredths of a degree on the models observed.
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            let value = Double(raw) / 100.0
            return (value > -50 && value < 150) ? value : nil
        }
        return nil
    }
}
