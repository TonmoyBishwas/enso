import Foundation
import SwiftUI
import Combine
import EnsoShared
import EnsoBattery

/// Top-level observable state: battery snapshots (direct, unprivileged) and
/// the daemon connection. One 5s heartbeat drives both while the app runs.
@MainActor
final class AppState: ObservableObject {
    @Published var battery: BatterySnapshot?
    @Published var config = EnsoConfig()
    @Published var lastError: String?
    @Published var installing = false

    let daemon = DaemonClient()

    private let reader = BatteryReader()
    private var timer: Timer?
    private var powerObserver: PowerSourceObserver?
    private var configSynced = false
    /// Newest daemon event we've already surfaced as a notification.
    private var lastSeenEventDate: Date = .now

    init() {
        refreshBattery()
        powerObserver = PowerSourceObserver { [weak self] in
            Task { @MainActor in self?.refreshBattery() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.heartbeat() }
        }
        Task { await heartbeat() }
    }

    func refreshBattery() {
        battery = try? reader.snapshot()
    }

    func heartbeat() async {
        refreshBattery()
        await daemon.refresh()
        // Adopt the daemon's persisted config once per connection so the UI
        // reflects reality (the daemon owns the config).
        if daemon.state == .ready, let status = daemon.status, !configSynced {
            config = status.config
            configSynced = true
        }
        if daemon.state != .ready {
            configSynced = false
        }
        surfaceNewEvents()
    }

    /// Turn daemon events the user hasn't seen into notifications.
    private func surfaceNewEvents() {
        guard UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true,
              let events = daemon.status?.recentEvents else { return }
        let fresh = events.filter { $0.date > lastSeenEventDate }
        guard !fresh.isEmpty else { return }
        lastSeenEventDate = fresh.map(\.date).max() ?? lastSeenEventDate
        NotificationManager.shared.requestAuthorizationIfNeeded()
        for event in fresh {
            NotificationManager.shared.post(kind: event.kind, message: event.message)
        }
    }

    /// Push the current UI config to the daemon.
    func pushConfig() {
        Task {
            lastError = await daemon.apply(config: config.validated())
        }
    }

    func run(_ command: DaemonCommand) {
        Task {
            lastError = await daemon.run(command: command)
        }
    }

    func installHelper() {
        installing = true
        lastError = nil
        Task {
            defer { installing = false }
            do {
                try HelperInstaller.install()
                // Give launchd a moment, then reconnect and push our config.
                try? await Task.sleep(for: .seconds(2))
                await daemon.refresh()
                if daemon.state == .ready {
                    _ = await daemon.apply(config: config.validated())
                }
            } catch HelperInstaller.InstallError.cancelled {
                // user backed out — not an error banner
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func uninstallHelper() {
        Task {
            _ = await daemon.run(command: .prepareUninstall)
            do {
                try HelperInstaller.uninstall()
                await daemon.refresh()
            } catch HelperInstaller.InstallError.cancelled {
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func quit() {
        if config.quitBehavior == .resetTo100 {
            run(.appWillQuit)
        }
        // Small delay so the XPC message gets out before the process dies.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }
}
