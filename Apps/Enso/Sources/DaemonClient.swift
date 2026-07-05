import Foundation
import EnsoShared

/// The app's connection to the root helper. All state hops back to the main
/// actor for SwiftUI.
@MainActor
final class DaemonClient: ObservableObject {
    enum ConnectionState: Equatable {
        case helperMissing        // binary not installed
        case connecting
        case ready
        case badSecret            // secret mismatch — reinstall helper
        case needsUpgrade         // protocol/version mismatch — reinstall helper
        case unreachable          // installed but not answering
    }

    @Published var state: ConnectionState = .connecting
    @Published var status: DaemonStatus?

    static let helperPath = "/Library/PrivilegedHelperTools/com.enso.daemon"

    private var connection: NSXPCConnection?
    private var handshaken = false

    nonisolated static var userSecretURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Enso/secret")
    }

    var helperInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.helperPath)
    }

    private func proxy() -> EnsoDaemonXPC? {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: ENSO_MACH_SERVICE, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: EnsoDaemonXPC.self)
            conn.invalidationHandler = { [weak self] in
                Task { @MainActor in
                    self?.connection = nil
                    self?.handshaken = false
                }
            }
            conn.resume()
            connection = conn
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in } as? EnsoDaemonXPC
    }

    /// One full refresh: verify install, handshake if needed, pull status.
    func refresh() async {
        guard helperInstalled else {
            state = .helperMissing
            status = nil
            return
        }
        if !handshaken {
            await handshake()
            guard handshaken else { return }
        }
        guard let proxy = proxy() else {
            state = .unreachable
            return
        }
        let data: Data? = await withCheckedContinuation { cont in
            var finished = false
            proxy.getStatus { reply in
                if !finished { finished = true; cont.resume(returning: reply) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !finished { finished = true; cont.resume(returning: nil) }
            }
        }
        guard let data, let decoded = try? JSONDecoder().decode(DaemonStatus.self, from: data) else {
            state = .unreachable
            handshaken = false
            return
        }
        // A daemonVersion difference alone is fine (UI-only releases don't
        // require an admin prompt); incompatible daemons are caught by the
        // protocol-version check in the handshake.
        state = .ready
        status = decoded
    }

    private func handshake() async {
        guard let secret = try? String(contentsOf: Self.userSecretURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            state = .badSecret
            return
        }
        guard let proxy = proxy() else {
            state = .unreachable
            return
        }
        let result: Int = await withCheckedContinuation { cont in
            var finished = false
            proxy.handshake(secret: secret, protocolVersion: DAEMON_PROTOCOL_VERSION) { code in
                if !finished { finished = true; cont.resume(returning: code) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !finished { finished = true; cont.resume(returning: -1) }
            }
        }
        switch HandshakeResult(rawValue: result) {
        case .ok:
            handshaken = true
            state = .ready
        case .badSecret:
            state = .badSecret
        case .protocolMismatch:
            state = .needsUpgrade
        default:
            state = .unreachable
        }
    }

    func apply(config: EnsoConfig) async -> String? {
        guard state == .ready, let proxy = proxy(),
              let json = try? JSONEncoder().encode(config) else { return "helper not ready" }
        let error: String? = await withCheckedContinuation { cont in
            var finished = false
            proxy.applyConfig(json) { reply in
                if !finished { finished = true; cont.resume(returning: reply) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !finished { finished = true; cont.resume(returning: "helper not responding") }
            }
        }
        await refresh()
        return error
    }

    func run(command: DaemonCommand) async -> String? {
        guard state == .ready, let proxy = proxy(),
              let json = try? JSONEncoder().encode(command) else { return "helper not ready" }
        let error: String? = await withCheckedContinuation { cont in
            var finished = false
            proxy.runCommand(json) { reply in
                if !finished { finished = true; cont.resume(returning: reply) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !finished { finished = true; cont.resume(returning: "helper not responding") }
            }
        }
        await refresh()
        return error
    }
}
