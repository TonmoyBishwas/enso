import Foundation
import IOKit

// Layout must match the kernel's SMCParamStruct exactly (80 bytes).
// Same definitions used by smcFanControl, SMCKit, BatFi, batt.

struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0          // aligns the struct with the C layout
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

enum SMCSelector {
    static let handleYPCEvent: UInt32 = 2
    static let readBytes: UInt8 = 5
    static let writeBytes: UInt8 = 6
    static let getKeyInfo: UInt8 = 9
}

enum SMCResultCode {
    static let keyNotFound: UInt8 = 0x84
}

/// Live connection to the AppleSMC kernel service. Reads work unprivileged;
/// writes require root (the daemon).
public final class SMCConnection: SMCService {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]
    private let lock = NSLock()

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { throw SMCError.openFailed(kern: result) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            SMCSelector.handleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else { throw SMCError.callFailed(kern: result) }
        guard output.result == 0 else {
            if output.result == SMCResultCode.keyNotFound {
                throw SMCError.keyNotFound(fourCC(input.key))
            }
            throw SMCError.smcResult(output.result)
        }
        return output
    }

    private func cachedKeyInfo(_ key: SMCKey) throws -> SMCKeyInfoData {
        lock.lock(); defer { lock.unlock() }
        if let cached = keyInfoCache[key.code] { return cached }
        var input = SMCParamStruct()
        input.key = key.code
        input.data8 = SMCSelector.getKeyInfo
        let output = try call(&input)
        keyInfoCache[key.code] = output.keyInfo
        return output.keyInfo
    }

    public func keyInfo(_ key: SMCKey) throws -> (type: UInt32, size: Int) {
        let info = try cachedKeyInfo(key)
        return (info.dataType, Int(info.dataSize))
    }

    public func readBytes(_ key: SMCKey) throws -> [UInt8] {
        let info = try cachedKeyInfo(key)
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCSelector.readBytes
        let output = try call(&input)
        return withUnsafeBytes(of: output.bytes) { raw in
            Array(raw.prefix(Int(info.dataSize)))
        }
    }

    public func writeBytes(_ key: SMCKey, _ bytes: [UInt8]) throws {
        guard geteuid() == 0 else { throw SMCError.notRoot }
        let info = try cachedKeyInfo(key)
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCSelector.writeBytes
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, byte) in bytes.prefix(32).enumerated() {
                raw[i] = byte
            }
        }
        _ = try call(&input)
    }
}

func fourCC(_ code: UInt32) -> String {
    let chars: [Character] = (0..<4).reversed().map {
        Character(UnicodeScalar(UInt8((code >> ($0 * 8)) & 0xFF)))
    }
    return String(chars)
}
