import SwiftUI
import EnsoShared
import EnsoBattery

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showTrueBatteryHealth") private var showTrueHealth = false

    var body: some View {
        VStack(spacing: 14) {
            header
            limitSection
            helperBanner
            statsGrid
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: header — charge ring with limit tick (the one signature element)

    private var header: some View {
        HStack(spacing: 16) {
            ChargeRing(
                soc: state.battery?.socPercent ?? 0,
                limit: state.config.chargeLimit,
                isCharging: state.battery?.isCharging ?? false
            )
            .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(state.battery?.socPercent ?? 0)%")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let sub = substatusLine {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var statusLine: String {
        guard let battery = state.battery else { return "Reading battery…" }
        if !battery.isAdapterConnected { return "On battery" }
        switch state.daemon.status?.currentAction {
        case "inhibit": return "Holding at limit"
        case "forceDischarge": return "Discharging"
        default: return battery.isCharging ? "Charging" : "Plugged in"
        }
    }

    private var substatusLine: String? {
        if let task = state.daemon.status?.activeTask {
            if task == "topUp" { return "Top Up active" }
            if task.hasPrefix("calibration") { return "Calibrating" }
            if task == "discharge" { return "Discharge in progress" }
        }
        if state.daemon.status?.failsafeActive == true { return "Failsafe: charging allowed" }
        if let battery = state.battery, !battery.isAdapterConnected,
           let mins = battery.timeRemainingMinutes {
            return String(format: "%d:%02d remaining", mins / 60, mins % 60)
        }
        return nil
    }

    // MARK: charge limit

    private var limitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Charge Limit")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(state.config.chargeLimit)%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(state.config.chargeLimit == 100 ? .secondary : .primary)
            }
            Slider(
                value: Binding(
                    get: { Double(state.config.chargeLimit) },
                    set: { state.config.chargeLimit = Int($0.rounded()) }
                ),
                in: Double(ChargeLimits.minimum)...Double(ChargeLimits.maximum),
                step: 1
            ) { editing in
                if !editing { state.pushConfig() }
            }
            .disabled(state.daemon.state != .ready)
            HStack {
                Text("50%").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("80% recommended").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("100%").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: helper banner

    @ViewBuilder
    private var helperBanner: some View {
        switch state.daemon.state {
        case .ready:
            EmptyView()
        case .helperMissing:
            banner(
                icon: "wrench.and.screwdriver",
                text: "Install the charging helper to enable limiting.",
                buttonTitle: state.installing ? "Installing…" : "Install Helper",
                disabled: state.installing
            ) { state.installHelper() }
        case .needsUpgrade, .badSecret:
            banner(
                icon: "arrow.triangle.2.circlepath",
                text: "The charging helper needs to be updated.",
                buttonTitle: state.installing ? "Updating…" : "Update Helper",
                disabled: state.installing
            ) { state.installHelper() }
        case .connecting:
            EmptyView()
        case .unreachable:
            banner(
                icon: "exclamationmark.triangle",
                text: "Helper isn’t responding.",
                buttonTitle: "Reinstall",
                disabled: state.installing
            ) { state.installHelper() }
        }
        if let error = state.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func banner(icon: String, text: String, buttonTitle: String,
                        disabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            installButton(title: buttonTitle, disabled: disabled, action: action)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func installButton(title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        if #available(macOS 26.0, *) {
            Button(title, action: action)
                .buttonStyle(.glassProminent)
                .disabled(disabled)
        } else {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(disabled)
        }
    }

    // MARK: stats

    private var statsGrid: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                stat("Health", state.battery.map { healthText(for: $0.healthPercent) } ?? "—",
                     help: healthHelp)
                stat("Cycles", state.battery.map { "\($0.cycleCount)" } ?? "—")
            }
            GridRow {
                stat("Temperature", state.battery?.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "—")
                stat("Power Source", powerSource)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var powerSource: String {
        guard let battery = state.battery else { return "—" }
        if battery.isAdapterConnected {
            if let watts = battery.adapterWatts { return "\(watts) W adapter" }
            return "Adapter"
        }
        return "Battery"
    }

    /// Like Apple's Battery Health screen, cap at 100% by default — a young
    /// battery can exceed its factory rating, which reads as "broken" to most
    /// people. The true value is opt-in via Settings.
    private func healthText(for health: Double) -> String {
        String(format: "%.0f%%", showTrueHealth ? health : min(health, 100))
    }

    private var healthHelp: String {
        guard let battery = state.battery else { return "" }
        let base = "Current maximum capacity (\(battery.maxCapacitymAh) mAh) vs. the factory design rating (\(battery.designCapacitymAh) mAh)."
        if battery.healthPercent > 100 && !showTrueHealth {
            return base + " The true value is above 100% — new batteries often exceed their conservative rating. Enable “Show true battery health” in Settings to display it."
        }
        if battery.healthPercent > 100 {
            return base + " New batteries often hold a little more than their conservative rating, so values above 100% are normal."
        }
        return base
    }

    private func stat(_ label: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            Spacer()

            Text("Enso \(ENSO_VERSION)")
                .font(.caption2)
                .foregroundStyle(.quaternary)

            Spacer()

            Button {
                state.quit()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit Enso")
        }
    }
}

/// SoC ring with a tick marking the charge limit — Enso's signature element.
struct ChargeRing: View {
    let soc: Int
    let limit: Int
    let isCharging: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(soc) / 100)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: soc)
            // Limit tick.
            if limit < 100 {
                Rectangle()
                    .fill(.primary.opacity(0.55))
                    .frame(width: 2.5, height: 10)
                    .offset(y: -34)
                    .rotationEffect(.degrees(Double(limit) / 100 * 360))
            }
            Image(systemName: isCharging ? "bolt.fill" : "battery.100percent")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(ringColor)
        }
        .padding(3)
    }

    private var ringColor: Color {
        if soc <= 15 { return .red }
        if soc >= limit { return .green }
        return .accentColor
    }
}
