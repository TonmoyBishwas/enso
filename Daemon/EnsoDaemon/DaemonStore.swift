import Foundation
import EnsoShared
import EnsoEngine

/// Persists config + engine memory so a daemon crash/restart resumes exactly
/// where it left off. Root-owned directory.
struct DaemonStore {
    static let supportDir = URL(fileURLWithPath: "/Library/Application Support/com.enso.daemon")
    let configURL: URL
    let memoryURL: URL
    let secretURL: URL

    init(directory: URL = DaemonStore.supportDir) {
        configURL = directory.appendingPathComponent("config.json")
        memoryURL = directory.appendingPathComponent("engine-memory.json")
        secretURL = directory.appendingPathComponent("secret")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadConfig() -> EnsoConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(EnsoConfig.self, from: data) else {
            return EnsoConfig()
        }
        return config.validated()
    }

    func save(config: EnsoConfig) {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    func loadMemory() -> EngineMemory {
        guard let data = try? Data(contentsOf: memoryURL),
              let memory = try? JSONDecoder().decode(EngineMemory.self, from: data) else {
            return EngineMemory()
        }
        return memory
    }

    func save(memory: EngineMemory) {
        if let data = try? JSONEncoder().encode(memory) {
            try? data.write(to: memoryURL, options: .atomic)
        }
    }

    func loadSecret() -> String? {
        (try? String(contentsOf: secretURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
