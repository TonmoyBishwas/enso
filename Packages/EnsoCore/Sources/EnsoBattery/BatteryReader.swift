import Foundation
import IOKit
import IOKit.ps

/// One unprivileged snapshot of the battery, from the AppleSmartBattery
/// IORegistry node. Everything the UI and the daemon's maintain loop need.
public struct BatterySnapshot: Codable, Equatable, Sendable {
    public var socPercent: Int              // macOS-smoothed CurrentCapacity
    public var isCharging: Bool
    public var isAdapterConnected: Bool
    public var fullyCharged: Bool
    public var cycleCount: Int
    public var designCapacitymAh: Int
    public var maxCapacitymAh: Int          // AppleRawMaxCapacity
    public var currentCapacitymAh: Int      // AppleRawCurrentCapacity
    public var temperatureCelsius: Double?  // from IORegistry (centi-°C)
    public var voltageMilliV: Int
    public var amperageMilliA: Int
    public var timeRemainingMinutes: Int?
    public var adapterWatts: Int?
    public var adapterDescription: String?
    public var timestamp: Date

    public var healthPercent: Double {
        guard designCapacitymAh > 0 else { return 0 }
        return Double(maxCapacitymAh) / Double(designCapacitymAh) * 100
    }
}

public enum BatteryReaderError: Error {
    case serviceNotFound
    case propertiesUnavailable
}

public struct BatteryReader {
    public init() {}

    public func snapshot(now: Date = Date()) throws -> BatterySnapshot {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { throw BatteryReaderError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else {
            throw BatteryReaderError.propertiesUnavailable
        }

        func int(_ key: String) -> Int? { props[key] as? Int }
        func bool(_ key: String) -> Bool { (props[key] as? Bool) ?? false }

        // Temperature is centi-°C (e.g. 3049 = 30.49°C).
        let temp = int("Temperature").map { Double($0) / 100.0 }
        // TimeRemaining of 65535 means "calculating".
        let rawTime = int("TimeRemaining") ?? 0
        let timeRemaining = (rawTime > 0 && rawTime < 65535) ? rawTime : nil

        let adapter = props["AdapterDetails"] as? [String: Any]

        return BatterySnapshot(
            socPercent: int("CurrentCapacity") ?? 0,
            isCharging: bool("IsCharging"),
            isAdapterConnected: bool("ExternalConnected"),
            fullyCharged: bool("FullyCharged"),
            cycleCount: int("CycleCount") ?? 0,
            designCapacitymAh: int("DesignCapacity") ?? 0,
            maxCapacitymAh: int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? 0,
            currentCapacitymAh: int("AppleRawCurrentCapacity") ?? 0,
            temperatureCelsius: temp,
            voltageMilliV: int("Voltage") ?? 0,
            amperageMilliA: int("Amperage").map { Int(Int64(truncatingIfNeeded: $0)) } ?? 0,
            timeRemainingMinutes: timeRemaining,
            adapterWatts: adapter?["Watts"] as? Int,
            adapterDescription: adapter?["Description"] as? String,
            timestamp: now
        )
    }
}

/// Fires a callback whenever macOS reports a power-source change
/// (plug/unplug, SoC change). Wraps IOPSNotificationCreateRunLoopSource.
public final class PowerSourceObserver {
    private var runLoopSource: CFRunLoopSource?
    private let callback: () -> Void

    public init(callback: @escaping () -> Void) {
        self.callback = callback
        let context = Unmanaged.passUnretained(self).toOpaque()
        runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<PowerSourceObserver>.fromOpaque(context).takeUnretainedValue()
            observer.callback()
        }, context)?.takeRetainedValue()
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}
