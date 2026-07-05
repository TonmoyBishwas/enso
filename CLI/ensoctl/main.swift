import Foundation
import EnsoShared
import EnsoSMC
import EnsoBattery

// ensoctl — Enso's command-line interface.
// Debug subcommands talk straight to the SMC (read-only, unprivileged).
// Control subcommands talk to the root daemon over XPC.

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    usage: ensoctl <command>

    Daemon control (requires the Enso helper to be installed):
      status                 show daemon state, strategy, current action
      limit <50-100>         set the charge limit
      topup                  charge to 100% once, then return to the limit
      discharge <15-100>     drain to a target while on AC
      calibrate              run a full calibration cycle
      cancel                 cancel the active task
      uninstall-prepare      restore all SMC keys to stock (pre-uninstall)

    Debug (no daemon needed, read-only):
      debug probe            show which SMC charging keys this Mac has
      debug dump-keys        dump raw values of every Enso-relevant key
      debug battery          print an AppleSmartBattery snapshot
    """)
    exit(2)
}

guard let command = args.first else { usage() }

// MARK: - Debug commands (direct, read-only)

func runDebug(_ sub: String) {
    let smc: SMCConnection
    do {
        smc = try SMCConnection()
    } catch {
        fputs("cannot open AppleSMC: \(error)\n", stderr)
        exit(1)
    }

    switch sub {
    case "probe":
        let caps = SMCCapabilities.probe(smc)
        print("strategy:          \(caps.strategy.rawValue)")
        print("adapter control:   \(caps.hasAdapterControl)")
        print("magsafe led:       \(caps.hasMagSafeLED)")
        print("hardware soc:      \(caps.hasHardwareSoC)")
        print("battery temp:      \(caps.hasBatteryTemp)")
        print("native limit flag: \(caps.hasNativeLimitFlag)")

    case "dump-keys":
        let keys: [SMCKey] = [
            SMCKeys.chte, SMCKeys.chie, SMCKeys.ch0b, SMCKeys.ch0c,
            SMCKeys.ch0i, SMCKeys.chwa, SMCKeys.aclc, SMCKeys.buic,
            SMCKeys.b0ct, SMCKeys.tb0t, SMCKeys.tb1t, SMCKeys.tb2t,
            SMCKeys.pdtr, SMCKeys.ppbr, SMCKeys.pstr, SMCKeys.acw,
        ]
        for key in keys {
            do {
                let info = try smc.keyInfo(key)
                let bytes = try smc.readBytes(key)
                let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                print("\(key.name)  type=\(fourCC(info.type))  size=\(info.size)  [\(hex)]")
            } catch {
                print("\(key.name)  <absent>")
            }
        }

    case "battery":
        do {
            let snap = try BatteryReader().snapshot()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(data: try encoder.encode(snap), encoding: .utf8)!)
            print(String(format: "health: %.1f%%", snap.healthPercent))
        } catch {
            fputs("battery read failed: \(error)\n", stderr)
            exit(1)
        }

    default:
        usage()
    }
}

// MARK: - Daemon commands (XPC)

final class XPCClient {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: ENSO_MACH_SERVICE, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: EnsoDaemonXPC.self)
        connection.resume()
    }

    func proxy() -> EnsoDaemonXPC? {
        var failed = false
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            fputs("XPC error: \(error.localizedDescription)\n", stderr)
            fputs("Is the Enso helper installed? (install it from the Enso app)\n", stderr)
            failed = true
        } as? EnsoDaemonXPC
        return failed ? nil : proxy
    }

    func handshake(_ proxy: EnsoDaemonXPC) -> Bool {
        guard let secret = ClientSecret.load() else {
            fputs("no client secret at \(ClientSecret.userPath.path); reinstall the helper\n", stderr)
            return false
        }
        let sema = DispatchSemaphore(value: 0)
        var ok = false
        proxy.handshake(secret: secret, protocolVersion: DAEMON_PROTOCOL_VERSION) { result in
            switch HandshakeResult(rawValue: result) {
            case .ok: ok = true
            case .badSecret: fputs("handshake rejected: bad secret\n", stderr)
            case .protocolMismatch: fputs("helper is a different version — update it from the Enso app\n", stderr)
            default: fputs("handshake failed (\(result))\n", stderr)
            }
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 5)
        return ok
    }
}

enum ClientSecret {
    static var userPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Enso/secret")
    }
    static func load() -> String? {
        (try? String(contentsOf: userPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func withDaemon(_ body: (EnsoDaemonXPC, @escaping () -> Void) -> Void) {
    let client = XPCClient()
    guard let proxy = client.proxy(), client.handshake(proxy) else { exit(1) }
    let sema = DispatchSemaphore(value: 0)
    body(proxy) { sema.signal() }
    if sema.wait(timeout: .now() + 10) == .timedOut {
        fputs("daemon did not respond\n", stderr)
        exit(1)
    }
}

func sendCommand(_ command: DaemonCommand) {
    withDaemon { proxy, done in
        let data = try! JSONEncoder().encode(command)
        proxy.runCommand(data) { error in
            if let error { fputs("error: \(error)\n", stderr); exit(1) }
            print("ok")
            done()
        }
    }
}

switch command {
case "debug":
    guard args.count >= 2 else { usage() }
    runDebug(args[1])

case "status":
    withDaemon { proxy, done in
        proxy.getStatus { data in
            guard let data,
                  let status = try? JSONDecoder().decode(DaemonStatus.self, from: data) else {
                fputs("could not decode status\n", stderr); exit(1)
            }
            print("daemon:     \(status.daemonVersion) (protocol \(status.protocolVersion))")
            print("strategy:   \(status.strategy.rawValue)")
            print("action:     \(status.currentAction)")
            print("task:       \(status.activeTask ?? "none")")
            print("limit:      \(status.config.chargeLimit)%\(status.config.sailingEnabled ? " (sailing ≥\(status.config.sailingLowerLimit)%)" : "")")
            print("failsafe:   \(status.failsafeActive)")
            done()
        }
    }

case "limit":
    guard args.count >= 2, let value = Int(args[1]) else { usage() }
    guard (ChargeLimits.minimum...ChargeLimits.maximum).contains(value) else {
        fputs("limit must be \(ChargeLimits.minimum)-\(ChargeLimits.maximum)\n", stderr)
        exit(2)
    }
    withDaemon { proxy, done in
        proxy.getStatus { data in
            guard let data,
                  var status = try? JSONDecoder().decode(DaemonStatus.self, from: data) else {
                fputs("could not read current config\n", stderr); exit(1)
            }
            status.config.chargeLimit = value
            let json = try! JSONEncoder().encode(status.config)
            proxy.applyConfig(json) { error in
                if let error { fputs("error: \(error)\n", stderr); exit(1) }
                print("charge limit set to \(value)%")
                done()
            }
        }
    }

case "topup": sendCommand(.topUp)
case "discharge":
    guard args.count >= 2, let target = Int(args[1]) else { usage() }
    sendCommand(.discharge(target: target))
case "calibrate": sendCommand(.calibrateNow)
case "cancel": sendCommand(.cancelTask)
case "uninstall-prepare": sendCommand(.prepareUninstall)

default:
    usage()
}
