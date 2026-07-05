import Foundation
import IOKit
import IOKit.pwr_mgt

// IOMessage.h constants are #define macros Swift can't import.
// iokit_common_msg(x) = 0xE0000000 | x
private let kIOMessageCanSystemSleep: UInt32 = 0xE0000270
private let kIOMessageSystemWillSleep: UInt32 = 0xE0000280
private let kIOMessageSystemHasPoweredOn: UInt32 = 0xE0000300

/// Wraps IORegisterForSystemPower. Delivers sleep/wake transitions to the
/// daemon and lets it veto idle sleep while a charge cycle is running.
final class PowerEvents {
    enum Event {
        case canSleep(veto: () -> Void, allow: () -> Void)
        case willSleep(acknowledge: () -> Void)
        case didWake
    }

    private var rootPort: io_connect_t = 0
    private var notifierObject: io_object_t = 0
    private var notificationPort: IONotificationPortRef?
    private let handler: (Event) -> Void

    init?(handler: @escaping (Event) -> Void) {
        self.handler = handler
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notificationPort, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let events = Unmanaged<PowerEvents>.fromOpaque(refcon).takeUnretainedValue()
            events.dispatch(messageType: messageType, argument: messageArgument)
        }, &notifierObject)
        guard rootPort != 0, let port = notificationPort else { return nil }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
    }

    private func dispatch(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        let ack = Int(bitPattern: argument)
        switch messageType {
        case kIOMessageCanSystemSleep:
            handler(.canSleep(
                veto: { [rootPort] in IOCancelPowerChange(rootPort, ack) },
                allow: { [rootPort] in IOAllowPowerChange(rootPort, ack) }
            ))
        case kIOMessageSystemWillSleep:
            // Forced sleep — cannot be vetoed, must acknowledge within 30s.
            handler(.willSleep(
                acknowledge: { [rootPort] in IOAllowPowerChange(rootPort, ack) }
            ))
        case kIOMessageSystemHasPoweredOn:
            handler(.didWake)
        default:
            break
        }
    }

    deinit {
        if let port = notificationPort {
            IODeregisterForSystemPower(&notifierObject)
            IOServiceClose(rootPort)
            IONotificationPortDestroy(port)
        }
    }
}

/// Holds/releases the dark-wake assertion that keeps charging alive while
/// the lid is closed on AC.
final class SleepAssertion {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isHeld = false

    func hold(reason: String) {
        guard !isHeld else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        isHeld = (result == kIOReturnSuccess)
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHeld = false
    }
}
