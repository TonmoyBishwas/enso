import Foundation

/// Four-character SMC key code, e.g. "CHTE", "CH0B".
public struct SMCKey: Hashable, CustomStringConvertible, Sendable {
    public let code: UInt32
    public let name: String

    public init(_ name: String) {
        precondition(name.utf8.count == 4, "SMC keys are exactly 4 ASCII chars")
        self.name = name
        var value: UInt32 = 0
        for byte in name.utf8 {
            value = (value << 8) | UInt32(byte)
        }
        self.code = value
    }

    public var description: String { name }
}

public enum SMCKeys {
    // Charging control — Tahoe (macOS 26) firmware
    public static let chte = SMCKey("CHTE")  // u32: 1 = inhibit charging, 0 = allow
    public static let chie = SMCKey("CHIE")  // u8: 0x08 = adapter off / force discharge, 0x00 = normal
    // Charging control — pre-Tahoe
    public static let ch0b = SMCKey("CH0B")  // u8: 0x02 = inhibit, 0x00 = allow (write with CH0C)
    public static let ch0c = SMCKey("CH0C")
    public static let ch0i = SMCKey("CH0I")  // u8: 0x01 = force discharge
    // Apple's fixed 80% limit flag (defer-to-native mode only)
    public static let chwa = SMCKey("CHWA")
    // MagSafe LED
    public static let aclc = SMCKey("ACLC")
    // Telemetry
    public static let buic = SMCKey("BUIC")  // hardware SoC %
    public static let b0ct = SMCKey("B0CT")  // cycle count
    public static let tb0t = SMCKey("TB0T")  // battery temp sensors
    public static let tb1t = SMCKey("TB1T")
    public static let tb2t = SMCKey("TB2T")
    public static let pdtr = SMCKey("PDTR")  // DC-in power
    public static let ppbr = SMCKey("PPBR")  // battery power
    public static let pstr = SMCKey("PSTR")  // system power
    public static let acw = SMCKey("AC-W")   // adapter state
}

public enum MagSafeLEDValue: UInt8, Sendable {
    case system = 0x00
    case off = 0x01
    case green = 0x03
    case amber = 0x04
}

public enum SMCError: Error, Equatable, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern: Int32)
    case callFailed(kern: Int32)
    case smcResult(UInt8)           // non-zero SMC result code (0x84 = key not found)
    case keyNotFound(String)
    case writeVerifyFailed(String)
    case notRoot

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let k): return "IOServiceOpen failed: \(String(k, radix: 16))"
        case .callFailed(let k): return "IOConnectCallStructMethod failed: \(String(k, radix: 16))"
        case .smcResult(let r): return "SMC returned result 0x\(String(r, radix: 16))"
        case .keyNotFound(let k): return "SMC key \(k) not present"
        case .writeVerifyFailed(let k): return "write to \(k) did not read back"
        case .notRoot: return "SMC writes require root"
        }
    }
}

/// Everything the daemon/app needs from the SMC, mockable for tests.
public protocol SMCService: AnyObject {
    /// Returns (dataType fourcc, size) or throws .keyNotFound.
    func keyInfo(_ key: SMCKey) throws -> (type: UInt32, size: Int)
    func readBytes(_ key: SMCKey) throws -> [UInt8]
    func writeBytes(_ key: SMCKey, _ bytes: [UInt8]) throws
}

public extension SMCService {
    func keyExists(_ key: SMCKey) -> Bool {
        (try? keyInfo(key)) != nil
    }

    /// Write then read back; throws .writeVerifyFailed on drift.
    func writeVerified(_ key: SMCKey, _ bytes: [UInt8]) throws {
        try writeBytes(key, bytes)
        let back = try readBytes(key)
        // Some firmwares echo inhibit values back with extra bits set
        // (CH0B reads 0x03 after writing 0x02) — compare "off vs on", not bytes.
        let wroteZero = bytes.allSatisfy { $0 == 0 }
        let readZero = back.allSatisfy { $0 == 0 }
        guard wroteZero == readZero else {
            throw SMCError.writeVerifyFailed(key.name)
        }
    }
}
