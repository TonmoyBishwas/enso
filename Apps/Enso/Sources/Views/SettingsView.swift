import SwiftUI
import ServiceManagement
import EnsoShared

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmUninstall = false
    @AppStorage("showTrueBatteryHealth") private var showTrueHealth = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }

                Picker("When Enso quits", selection: $state.config.quitBehavior) {
                    Text("Keep enforcing the limit").tag(QuitBehavior.keepLimiting)
                    Text("Charge normally to 100%").tag(QuitBehavior.resetTo100)
                }
                .onChange(of: state.config.quitBehavior) { _, _ in state.pushConfig() }
            }

            Section("Charging") {
                Toggle("Stop charging before sleep", isOn: $state.config.stopChargingWhenSleeping)
                    .onChange(of: state.config.stopChargingWhenSleeping) { _, _ in state.pushConfig() }
                Text("Prevents the battery from creeping to 100% overnight while plugged in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Keep Mac awake until limit is reached", isOn: $state.config.preventSleepUntilLimit)
                    .onChange(of: state.config.preventSleepUntilLimit) { _, _ in state.pushConfig() }

                Toggle("Use hardware battery percentage", isOn: $state.config.useHardwarePercentage)
                    .onChange(of: state.config.useHardwarePercentage) { _, _ in state.pushConfig() }
                Text("Reads the battery's own gauge, which can differ a few percent from the value macOS shows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show true battery health", isOn: $showTrueHealth)
                Text("A young battery can hold more than its factory rating, so its true health can read above 100%. Off, the value is capped at 100% like Apple's Battery Health screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Helper") {
                LabeledContent("Status", value: helperStatusText)
                LabeledContent("Version", value: state.daemon.status?.daemonVersion ?? "—")
                LabeledContent("Key strategy", value: state.daemon.status?.strategy.rawValue ?? "—")

                Button("Uninstall Helper…", role: .destructive) {
                    confirmUninstall = true
                }
                .confirmationDialog(
                    "Remove the charging helper?",
                    isPresented: $confirmUninstall
                ) {
                    Button("Restore stock charging and remove", role: .destructive) {
                        state.uninstallHelper()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your battery will charge to 100% as usual. You'll be asked for your administrator password.")
                }
            }

            Section {
                LabeledContent("Enso", value: ENSO_VERSION)
                Link("Source code & issues", destination: URL(string: "https://github.com/TonmoyBishwas/enso")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var helperStatusText: String {
        switch state.daemon.state {
        case .ready: return "Running"
        case .helperMissing: return "Not installed"
        case .connecting: return "Connecting…"
        case .needsUpgrade: return "Update required"
        case .badSecret: return "Reinstall required"
        case .unreachable: return "Not responding"
        }
    }
}
