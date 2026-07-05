import Foundation
import os
import EnsoShared

/// Per-connection exported object. Every method except handshake refuses to
/// act until the client has presented the install-time secret.
final class DaemonXPCService: NSObject, EnsoDaemonXPC {
    private let daemon: Daemon
    private let log = Logger(subsystem: "com.enso.daemon", category: "xpc")
    private var authenticated = false
    private let lock = NSLock()

    init(daemon: Daemon) {
        self.daemon = daemon
    }

    private var isAuthenticated: Bool {
        lock.lock(); defer { lock.unlock() }
        return authenticated
    }

    func handshake(secret: String, protocolVersion: Int, reply: @escaping (Int) -> Void) {
        guard protocolVersion == DAEMON_PROTOCOL_VERSION else {
            log.error("handshake: protocol mismatch (client \(protocolVersion), daemon \(DAEMON_PROTOCOL_VERSION))")
            reply(HandshakeResult.protocolMismatch.rawValue)
            return
        }
        guard let expected = daemon.secret(), constantTimeEquals(secret, expected) else {
            log.error("handshake: bad secret")
            reply(HandshakeResult.badSecret.rawValue)
            return
        }
        lock.lock()
        authenticated = true
        lock.unlock()
        reply(HandshakeResult.ok.rawValue)
    }

    func getStatus(reply: @escaping (Data?) -> Void) {
        guard isAuthenticated else { reply(nil); return }
        reply(try? JSONEncoder().encode(daemon.currentStatus()))
    }

    func applyConfig(_ json: Data, reply: @escaping (String?) -> Void) {
        guard isAuthenticated else { reply("not authenticated"); return }
        guard let config = try? JSONDecoder().decode(EnsoConfig.self, from: json) else {
            reply("malformed config")
            return
        }
        reply(daemon.apply(newConfig: config))
    }

    func runCommand(_ json: Data, reply: @escaping (String?) -> Void) {
        guard isAuthenticated else { reply("not authenticated"); return }
        guard let command = try? JSONDecoder().decode(DaemonCommand.self, from: json) else {
            reply("malformed command")
            return
        }
        reply(daemon.run(command: command))
    }
}

private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8), bBytes = Array(b.utf8)
    guard aBytes.count == bBytes.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<aBytes.count { diff |= aBytes[i] ^ bBytes[i] }
    return diff == 0
}

final class XPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let daemon: Daemon

    init(daemon: Daemon) {
        self.daemon = daemon
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Without Developer ID signing we cannot pin the client's code
        // signature; authentication happens per-connection via the
        // install-time shared secret in handshake(). The protocol surface is
        // deliberately minimal and every value is re-validated daemon-side.
        connection.exportedInterface = NSXPCInterface(with: EnsoDaemonXPC.self)
        connection.exportedObject = DaemonXPCService(daemon: daemon)
        connection.resume()
        return true
    }
}
