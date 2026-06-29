import XCTest
@testable import OuraProtocol

final class OuraCommandsTests: XCTestCase {

    // MARK: - Auth commands wire format

    func testReqAuthNonceFormat() {
        // Expected: [0x2F][0x02][0x01][0x2B] — outer tag 0x2F, payload [0x01, 0x2B]
        let cmd = reqAuthNonce()
        XCTAssertEqual(Array(cmd), [0x2F, 0x02, 0x01, 0x2B])
    }

    func testReqAuthenticateFormat() {
        let encrypted = [UInt8](repeating: 0xAB, count: 16)
        let cmd = reqAuthenticate(encrypted: encrypted)
        // [0x2F][0x12][0x11][0x2D][16 bytes]
        XCTAssertEqual(cmd[0], 0x2F)
        XCTAssertEqual(cmd[1], 18)     // length = 2 (sub-opcodes) + 16 (ciphertext)
        XCTAssertEqual(cmd[2], 0x11)
        XCTAssertEqual(cmd[3], 0x2D)
        XCTAssertEqual(Array(cmd[4...]), encrypted)
    }

    func testReqSetAuthKeyFormat() {
        let key = [UInt8](0..<16)
        let cmd = reqSetAuthKey(key: key)
        // [0x24][0x11][0x10][16 bytes key]
        XCTAssertEqual(cmd[0], 0x24)
        XCTAssertEqual(cmd[1], 17)      // length = 1 (sub-opcode 0x10) + 16 (key)
        XCTAssertEqual(cmd[2], 0x10)
        XCTAssertEqual(Array(cmd[3...]), key)
    }

    // MARK: - Time sync

    func testReqSyncTimeZeroTimestamp() {
        let cmd = reqSyncTime(unixSecs: 0, tzHalfHours: 0)
        // [0x12][0x09][8 zero bytes for ts][0x00 tz]
        XCTAssertEqual(cmd[0], 0x12)
        XCTAssertEqual(cmd[1], 9)
        XCTAssertEqual(Array(cmd[2..<10]), [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(cmd[10], 0x00)
    }

    func testReqSyncTimeLittleEndian() {
        // Unix timestamp 0x0102030405060708 → LE bytes [08,07,06,05,04,03,02,01]
        let ts: UInt64 = 0x0102030405060708
        let cmd = reqSyncTime(unixSecs: ts, tzHalfHours: 4)
        XCTAssertEqual(Array(cmd[2..<10]), [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(cmd[10], 4)
    }

    // MARK: - Feature mode

    func testReqSetFeatureModeFormat() {
        let cmd = reqSetFeatureMode(feature: .spo2, mode: .automatic)
        // [0x2F][0x03][0x22][feature.rawValue][mode.rawValue]
        XCTAssertEqual(cmd[0], 0x2F)
        XCTAssertEqual(cmd[1], 3)
        XCTAssertEqual(cmd[2], 0x22)
        XCTAssertEqual(cmd[3], OuraFeature.spo2.rawValue)
        XCTAssertEqual(cmd[4], OuraFeatureMode.automatic.rawValue)
    }

    // MARK: - Event drain

    func testReqGetEventZeroCursor() {
        let cmd = reqGetEvent(startDeciseconds: 0)
        XCTAssertEqual(cmd[0], 0x10)
        // payload = [u32 cursor LE][0x08 maxEvents][i32(-1) LE]
        XCTAssertEqual(cmd[1], 9)
        XCTAssertEqual(Array(cmd[2..<6]), [0x00, 0x00, 0x00, 0x00])  // cursor = 0
        XCTAssertEqual(cmd[6], 0x08)                                   // maxEvents = 8
        XCTAssertEqual(Array(cmd[7..<11]), [0xFF, 0xFF, 0xFF, 0xFF])  // flags = -1 LE
    }

    func testReqGetEventNonZeroCursor() {
        let cursor: UInt32 = 0x01020304
        let cmd = reqGetEvent(startDeciseconds: cursor)
        // Cursor [04, 03, 02, 01] in LE
        XCTAssertEqual(Array(cmd[2..<6]), [0x04, 0x03, 0x02, 0x01])
    }

    // MARK: - Response parsers

    func testParseNonceSuccess() {
        var packet: [UInt8] = [0x2F, 0x10, 0x2C]
        packet.append(contentsOf: [UInt8](repeating: 0xAB, count: 15))
        let nonce = parseNonce(Data(packet))
        XCTAssertEqual(nonce, [UInt8](repeating: 0xAB, count: 15))
    }

    func testParseNonceWrongTag() {
        var packet: [UInt8] = [0x10, 0x10, 0x2C]
        packet.append(contentsOf: [UInt8](repeating: 0, count: 15))
        XCTAssertNil(parseNonce(Data(packet)))
    }

    func testParseNonceTooShort() {
        XCTAssertNil(parseNonce(Data([0x2F, 0x02, 0x2C, 0x00])))
    }

    func testParseAuthResultSuccess() {
        let packet = Data([0x2F, 0x02, 0x2E, 0x00])
        XCTAssertEqual(parseAuthResult(packet), .success)
    }

    func testParseAuthResultError() {
        let packet = Data([0x2F, 0x02, 0x2E, 0x01])
        XCTAssertEqual(parseAuthResult(packet), .authenticationError)
    }

    func testParseAuthResultFactoryReset() {
        let packet = Data([0x2F, 0x02, 0x2E, 0x02])
        XCTAssertEqual(parseAuthResult(packet), .inFactoryReset)
    }

    func testParseAuthResultNotOriginalDevice() {
        let packet = Data([0x2F, 0x02, 0x2E, 0x03])
        XCTAssertEqual(parseAuthResult(packet), .notOriginalOnboardedDevice)
    }

    func testParseAuthResultUnknown() {
        let packet = Data([0x2F, 0x02, 0x2E, 0xFF])
        XCTAssertEqual(parseAuthResult(packet), .unknown)
    }

    func testParseAuthResultWrongSubopcode() {
        let packet = Data([0x2F, 0x02, 0x2F, 0x00])  // sub-opcode 0x2F ≠ 0x2E
        XCTAssertNil(parseAuthResult(packet))
    }

    func testEventBatchSummaryParsing() {
        // tag=0x10, len=5, events=3, bytesLeft=0x00000100 (256)
        let packet = Data([0x10, 0x05, 0x03, 0x00, 0x01, 0x00, 0x00])
        let summary = OuraEventBatchSummary(packet: packet)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.eventsInBatch, 3)
        XCTAssertEqual(summary?.bytesLeft, 256)
    }

    func testEventBatchSummaryZeroBytesLeft() {
        let packet = Data([0x10, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00])
        let summary = OuraEventBatchSummary(packet: packet)
        XCTAssertEqual(summary?.bytesLeft, 0)
    }

    func testEventBatchSummaryWrongTag() {
        let packet = Data([0x2F, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00])
        XCTAssertNil(OuraEventBatchSummary(packet: packet))
    }
}
