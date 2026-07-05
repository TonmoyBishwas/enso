import XCTest
@testable import EnsoSMC
import EnsoShared

final class SMCTests: XCTestCase {

    // The kernel rejects calls whose struct size is wrong, so this layout
    // check is load-bearing.
    func testParamStructIs80Bytes() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.stride, 80)
    }

    func testFourCCEncoding() {
        XCTAssertEqual(SMCKey("CHTE").code, 0x43485445)
        XCTAssertEqual(fourCC(SMCKey("CH0B").code), "CH0B")
        XCTAssertEqual(SMCKey("AC-W").name, "AC-W")
    }

    // MARK: capability probe decision table

    func testProbePicksTahoeWhenCHTEPresent() {
        let caps = SMCCapabilities.probe(MockSMC.tahoeMacBook())
        XCTAssertEqual(caps.strategy, .tahoe)
        XCTAssertTrue(caps.hasAdapterControl)
        XCTAssertTrue(caps.hasMagSafeLED)
        XCTAssertTrue(caps.hasNativeLimitFlag)
    }

    func testProbePicksLegacyWhenOnlyCH0BC() {
        let caps = SMCCapabilities.probe(MockSMC.legacyMacBook())
        XCTAssertEqual(caps.strategy, .legacy)
        XCTAssertTrue(caps.hasAdapterControl)
        XCTAssertFalse(caps.hasNativeLimitFlag)
    }

    func testProbeReportsNoneOnUnknownMachine() {
        let caps = SMCCapabilities.probe(MockSMC.noChargingKeys())
        XCTAssertEqual(caps.strategy, .none)
    }

    // MARK: charging control writes

    func testTahoeInhibitWritesCHTE() throws {
        let mock = MockSMC.tahoeMacBook()
        let control = ChargingControl(smc: mock)
        try control.apply(.inhibit)
        XCTAssertTrue(mock.writeLog.contains { $0.key == "CHTE" && $0.bytes == [1, 0, 0, 0] })
        try control.apply(.allow)
        XCTAssertTrue(mock.writeLog.contains { $0.key == "CHTE" && $0.bytes == [0, 0, 0, 0] })
    }

    func testLegacyInhibitWritesBothGates() throws {
        let mock = MockSMC.legacyMacBook()
        let control = ChargingControl(smc: mock)
        try control.apply(.inhibit)
        XCTAssertTrue(mock.writeLog.contains { $0.key == "CH0B" && $0.bytes == [2] })
        XCTAssertTrue(mock.writeLog.contains { $0.key == "CH0C" && $0.bytes == [2] })
    }

    func testForceDischargeSetsAdapterKeyAndInhibit() throws {
        let mock = MockSMC.tahoeMacBook()
        let control = ChargingControl(smc: mock)
        try control.apply(.forceDischarge)
        XCTAssertTrue(mock.writeLog.contains { $0.key == "CHIE" && $0.bytes == [0x08] })
        // Returning to allow must clear the adapter key first.
        try control.apply(.allow)
        XCTAssertTrue(mock.writeLog.contains { $0.key == "CHIE" && $0.bytes == [0x00] })
        XCTAssertEqual(try control.isChargingInhibited(), false)
    }

    func testApplyOnNoStrategyThrows() {
        let control = ChargingControl(smc: MockSMC.noChargingKeys())
        XCTAssertThrowsError(try control.apply(.inhibit))
    }

    func testWriteFailureSurfaces() {
        let mock = MockSMC.tahoeMacBook()
        let control = ChargingControl(smc: mock)
        mock.failNextWrites = 2
        XCTAssertThrowsError(try control.apply(.inhibit))
    }

    func testRestoreDefaultsClearsEverything() throws {
        let mock = MockSMC.tahoeMacBook()
        let control = ChargingControl(smc: mock)
        try control.apply(.forceDischarge)
        control.restoreDefaults()
        XCTAssertEqual(mock.store[SMCKeys.chte.code]?.bytes, [0, 0, 0, 0])
        XCTAssertEqual(mock.store[SMCKeys.chie.code]?.bytes, [0])
        XCTAssertEqual(mock.store[SMCKeys.aclc.code]?.bytes, [0])
    }

    // MARK: temperature decoding

    func testDecodeFloatTemperature() {
        let bytes = withUnsafeBytes(of: Float(31.25).bitPattern.littleEndian) { Array($0) }
        XCTAssertEqual(ChargingControl.decodeTemperature(type: SMCKey("flt ").code, bytes: bytes), 31.25)
    }

    func testDecodeSp78Temperature() {
        // 30.5°C in sp78: integer part 30, fraction 0x80/256
        let value = ChargingControl.decodeTemperature(type: SMCKey("sp78").code, bytes: [30, 0x80])
        XCTAssertEqual(value, 30.5)
    }

    func testHardwareSoCReadsBUIC() {
        let control = ChargingControl(smc: MockSMC.tahoeMacBook())
        XCTAssertEqual(control.hardwareSoC(), 72)
    }

    // MARK: dry run

    func testDryRunNeverTouchesUnderlying() throws {
        let mock = MockSMC.tahoeMacBook()
        var logs: [String] = []
        let dry = DryRunSMC(wrapping: mock) { logs.append($0) }
        let control = ChargingControl(smc: dry)
        try control.apply(.inhibit)
        XCTAssertTrue(mock.writeLog.isEmpty)
        XCTAssertFalse(logs.isEmpty)
    }
}
