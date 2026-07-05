import Foundation
import AppKit

/// Installs/upgrades/uninstalls the root helper by running the bundled
/// install script through a single admin prompt (osascript).
enum HelperInstaller {

    enum InstallError: LocalizedError {
        case resourcesMissing(String)
        case scriptFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .resourcesMissing(let what): return "Missing bundled resource: \(what)"
            case .scriptFailed(let message): return message
            case .cancelled: return "Installation was cancelled."
            }
        }
    }

    /// Locates a resource in the app bundle, falling back to the repo layout
    /// for `swift run` development builds.
    private static func locate(_ names: [String]) -> URL? {
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates += names.map { resources.appendingPathComponent($0) }
        }
        if let exeDir {
            candidates += names.map { exeDir.appendingPathComponent($0) }
            // Dev fallback: repo checkout relative to .build/debug
            let repoRoot = exeDir.deletingLastPathComponent().deletingLastPathComponent()
            candidates += names.map { repoRoot.appendingPathComponent("Scripts/\($0)") }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func install() throws {
        guard let script = locate(["install-daemon.sh"]) else {
            throw InstallError.resourcesMissing("install-daemon.sh")
        }
        guard let plist = locate(["com.enso.daemon.plist.template"]) else {
            throw InstallError.resourcesMissing("com.enso.daemon.plist.template")
        }
        guard let daemonBin = locate(["ensod"]) else {
            throw InstallError.resourcesMissing("ensod")
        }
        try runPrivileged(command: "/bin/bash \(q(script.path)) \(q(daemonBin.path)) \(q(plist.path)) \(q(NSUserName()))")
    }

    static func uninstall() throws {
        guard let script = locate(["uninstall.sh"]) else {
            throw InstallError.resourcesMissing("uninstall.sh")
        }
        try runPrivileged(command: "/bin/bash \(q(script.path))")
        try? FileManager.default.removeItem(at: DaemonClient.userSecretURL)
    }

    /// Shell-quote a path for the inner `do shell script` command.
    private static func q(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runPrivileged(command: String) throws {
        // Escape for the AppleScript string literal.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else {
            throw InstallError.scriptFailed("could not build install command")
        }
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -128 { throw InstallError.cancelled }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            throw InstallError.scriptFailed(message)
        }
    }
}
