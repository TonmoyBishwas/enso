import SwiftUI
import EnsoShared
import EnsoBattery

@main
struct EnsoApp: App {
    @StateObject private var state = AppState()
    private let debugWindow = ProcessInfo.processInfo.environment["ENSO_DEBUG_WINDOW"] != nil

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            MenuBarLabel(battery: state.battery, daemonReady: state.daemon.state == .ready)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }

        // Development aid: ENSO_DEBUG_WINDOW=1 opens the popover content in a
        // normal window (for screenshots / UI review). Without the variable
        // the window renders nothing and never auto-opens (LSUIElement app).
        WindowGroup("Enso Debug", id: "enso-debug") {
            if debugWindow {
                MenuBarView()
                    .environmentObject(state)
            }
        }
        .windowResizability(.contentSize)
    }
}

struct MenuBarLabel: View {
    let battery: BatterySnapshot?
    let daemonReady: Bool

    var body: some View {
        Image(systemName: symbolName)
    }

    private var symbolName: String {
        guard let battery else { return "minus.plus.batteryblock" }
        if battery.isAdapterConnected {
            return battery.isCharging ? "battery.100percent.bolt" : "powerplug"
        }
        let soc = battery.socPercent
        switch soc {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
