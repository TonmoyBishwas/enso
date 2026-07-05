import Foundation
import os
import EnsoShared

// ensod — Enso's privileged charging daemon.
// Runs as a LaunchDaemon (root). See docs/ARCHITECTURE.md.

let arguments = CommandLine.arguments
let dryRun = arguments.contains("--dry-run")

if arguments.contains("--version") {
    print(ENSO_DAEMON_VERSION)
    exit(0)
}

let mainLog = Logger(subsystem: "com.enso.daemon", category: "main")

guard geteuid() == 0 || dryRun else {
    fputs("ensod must run as root (use --dry-run for unprivileged soak testing)\n", stderr)
    exit(1)
}

let daemon = Daemon(dryRun: dryRun)

// Restore-on-exit: SIGTERM arrives on daemon unload / shutdown.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    mainLog.notice("SIGTERM — shutting down")
    daemon.shutdown()
    exit(0)
}
sigterm.resume()

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    mainLog.notice("SIGINT — shutting down")
    daemon.shutdown()
    exit(0)
}
sigint.resume()

let listener = NSXPCListener(machServiceName: ENSO_MACH_SERVICE)
let delegate = XPCListenerDelegate(daemon: daemon)
listener.delegate = delegate
listener.resume()

daemon.start()
mainLog.notice("ensod running (pid \(getpid()))")

RunLoop.main.run()
