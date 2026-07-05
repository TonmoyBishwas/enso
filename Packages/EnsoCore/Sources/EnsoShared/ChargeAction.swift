import Foundation

/// The three mutually exclusive things Enso can tell the SMC to do.
public enum ChargeAction: String, Codable, Equatable, Sendable {
    case allow
    case inhibit
    case forceDischarge
}

public enum LEDState: String, Codable, Equatable, Sendable {
    case system
    case off
    case green
    case amber
}
