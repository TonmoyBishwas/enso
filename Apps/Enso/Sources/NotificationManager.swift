import Foundation
import UserNotifications

/// Posts user notifications for daemon events. Requires a real app bundle
/// (UNUserNotificationCenter is unavailable in bare `swift run` binaries),
/// so everything degrades to a no-op in development runs.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var available: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private var authorizationRequested = false

    func requestAuthorizationIfNeeded() {
        guard available, !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Kinds worth interrupting the user for. Cancellations and phase
    /// changes stay in the popover only.
    private static let notifiableKinds: Set<String> = [
        "limitReached", "topUpDone", "dischargeDone",
        "heatPauseStarted", "calibrationDone", "failsafe",
    ]

    func post(kind: String, message: String) {
        guard available, Self.notifiableKinds.contains(kind) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Enso"
        content.body = message
        let request = UNNotificationRequest(
            identifier: "enso-\(kind)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
