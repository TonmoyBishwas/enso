import Foundation

/// Mach service name the daemon's XPC listener vends
/// (declared under MachServices in the LaunchDaemon plist).
public let ENSO_MACH_SERVICE = "com.enso.daemon.xpc"

/// Commands a client may ask the daemon to run. Fixed enum — there is
/// deliberately no "write arbitrary SMC key" escape hatch.
public enum DaemonCommand: Codable, Equatable, Sendable {
    case topUp
    case discharge(target: Int)
    case calibrateNow
    case cancelTask
    case appWillQuit
    /// Reset limit to 100, restore every touched SMC key, LED to system.
    case prepareUninstall
}

public enum HandshakeResult: Int, Codable, Sendable {
    case ok = 0
    case badSecret = 1
    case protocolMismatch = 2
}

/// A noteworthy engine event, timestamped by the daemon. The app polls these
/// via getStatus and turns fresh ones into user notifications.
public struct StampedEvent: Codable, Equatable, Sendable {
    /// Stable machine-readable kind, e.g. "limitReached", "dischargeDone".
    public var kind: String
    /// Human-readable message, ready to display.
    public var message: String
    public var date: Date

    public init(kind: String, message: String, date: Date) {
        self.kind = kind
        self.message = message
        self.date = date
    }
}

/// Snapshot of daemon state returned by getStatus, JSON-encoded over XPC.
public struct DaemonStatus: Codable, Equatable, Sendable {
    public enum ChargingStrategy: String, Codable, Sendable {
        case tahoe      // CHTE/CHIE
        case legacy     // CH0B+CH0C / CH0I
        case none       // no working keys — daemon is standing down
    }

    public var daemonVersion: String
    public var protocolVersion: Int
    public var strategy: ChargingStrategy
    public var config: EnsoConfig
    /// Engine's most recent action: "allow" | "inhibit" | "forceDischarge".
    public var currentAction: String
    /// Active task if any: "topUp" | "discharge" | "calibration:<phase>".
    public var activeTask: String?
    public var failsafeActive: Bool
    public var lastTickAt: Date?
    /// Recent engine events (ring buffer, newest last). Optional so payloads
    /// from older daemons still decode.
    public var recentEvents: [StampedEvent]?
    /// Whether this Mac's SMC exposes the MagSafe LED key. Optional for the
    /// same compatibility reason.
    public var hasMagSafeLED: Bool?

    public init(
        daemonVersion: String,
        protocolVersion: Int = DAEMON_PROTOCOL_VERSION,
        strategy: ChargingStrategy,
        config: EnsoConfig,
        currentAction: String,
        activeTask: String? = nil,
        failsafeActive: Bool = false,
        lastTickAt: Date? = nil,
        recentEvents: [StampedEvent]? = nil,
        hasMagSafeLED: Bool? = nil
    ) {
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.strategy = strategy
        self.config = config
        self.currentAction = currentAction
        self.activeTask = activeTask
        self.failsafeActive = failsafeActive
        self.lastTickAt = lastTickAt
        self.recentEvents = recentEvents
        self.hasMagSafeLED = hasMagSafeLED
    }
}

/// The complete privileged surface. Payloads are JSON `Data` of the types
/// above so NSSecureCoding stays trivial (NSData only).
@objc public protocol EnsoDaemonXPC {
    /// Must be called (successfully) before any other method is honored.
    func handshake(secret: String, protocolVersion: Int, reply: @escaping (Int) -> Void)
    func getStatus(reply: @escaping (Data?) -> Void)
    /// Full-config replace. Daemon runs `validated()` on it. Returns an error
    /// string or nil.
    func applyConfig(_ json: Data, reply: @escaping (String?) -> Void)
    /// Run a DaemonCommand (JSON). Returns an error string or nil.
    func runCommand(_ json: Data, reply: @escaping (String?) -> Void)
}
