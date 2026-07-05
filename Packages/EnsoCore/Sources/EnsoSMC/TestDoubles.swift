import Foundation

/// In-memory SMC for unit tests: seed it with a key inventory and inspect
/// what got written.
public final class MockSMC: SMCService {
    public struct Entry {
        public var type: UInt32
        public var bytes: [UInt8]
        public init(type: String, bytes: [UInt8]) {
            self.type = SMCKey(type).code
            self.bytes = bytes
        }
    }

    public private(set) var store: [UInt32: Entry]
    public private(set) var writeLog: [(key: String, bytes: [UInt8])] = []
    /// Set to make the next N writes fail (for error-streak tests).
    public var failNextWrites = 0

    public init(keys: [String: Entry]) {
        var s: [UInt32: Entry] = [:]
        for (name, entry) in keys { s[SMCKey(name).code] = entry }
        self.store = s
    }

    public func keyInfo(_ key: SMCKey) throws -> (type: UInt32, size: Int) {
        guard let entry = store[key.code] else { throw SMCError.keyNotFound(key.name) }
        return (entry.type, entry.bytes.count)
    }

    public func readBytes(_ key: SMCKey) throws -> [UInt8] {
        guard let entry = store[key.code] else { throw SMCError.keyNotFound(key.name) }
        return entry.bytes
    }

    public func writeBytes(_ key: SMCKey, _ bytes: [UInt8]) throws {
        guard store[key.code] != nil else { throw SMCError.keyNotFound(key.name) }
        if failNextWrites > 0 {
            failNextWrites -= 1
            throw SMCError.smcResult(0x01)
        }
        store[key.code]?.bytes = bytes
        writeLog.append((key.name, bytes))
    }

    /// A Tahoe-era MacBook: CHTE/CHIE, no CH0B/C.
    public static func tahoeMacBook() -> MockSMC {
        MockSMC(keys: [
            "CHTE": Entry(type: "ui32", bytes: [0, 0, 0, 0]),
            "CHIE": Entry(type: "ui8 ", bytes: [0]),
            "ACLC": Entry(type: "ui8 ", bytes: [0]),
            "BUIC": Entry(type: "ui8 ", bytes: [72]),
            "TB0T": Entry(type: "flt ", bytes: withUnsafeBytes(of: Float(30.5).bitPattern.littleEndian) { Array($0) }),
            "CHWA": Entry(type: "ui8 ", bytes: [0]),
        ])
    }

    /// A pre-Tahoe Apple Silicon MacBook: CH0B/CH0C/CH0I.
    public static func legacyMacBook() -> MockSMC {
        MockSMC(keys: [
            "CH0B": Entry(type: "hex_", bytes: [0]),
            "CH0C": Entry(type: "hex_", bytes: [0]),
            "CH0I": Entry(type: "ui8 ", bytes: [0]),
            "ACLC": Entry(type: "ui8 ", bytes: [0]),
            "BUIC": Entry(type: "ui8 ", bytes: [65]),
            "TB0T": Entry(type: "flt ", bytes: withUnsafeBytes(of: Float(28.0).bitPattern.littleEndian) { Array($0) }),
        ])
    }

    /// A desktop / unknown machine with no charging keys at all.
    public static func noChargingKeys() -> MockSMC {
        MockSMC(keys: [:])
    }
}

/// Wraps a real (read-only) connection but logs writes instead of performing
/// them — the daemon's --dry-run mode for safe soak testing on hardware.
public final class DryRunSMC: SMCService {
    private let underlying: SMCService
    private let log: (String) -> Void
    /// Pretend-writes are remembered so read-backs verify.
    private var shadow: [UInt32: [UInt8]] = [:]

    public init(wrapping underlying: SMCService, log: @escaping (String) -> Void) {
        self.underlying = underlying
        self.log = log
    }

    public func keyInfo(_ key: SMCKey) throws -> (type: UInt32, size: Int) {
        try underlying.keyInfo(key)
    }

    public func readBytes(_ key: SMCKey) throws -> [UInt8] {
        if let shadowed = shadow[key.code] { return shadowed }
        return try underlying.readBytes(key)
    }

    public func writeBytes(_ key: SMCKey, _ bytes: [UInt8]) throws {
        _ = try underlying.keyInfo(key) // still validate the key exists
        shadow[key.code] = bytes
        log("DRY-RUN would write \(key.name) = \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
    }
}
