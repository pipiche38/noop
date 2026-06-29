import XCTest
@testable import OuraProtocol

final class OuraFramingTests: XCTestCase {

    // MARK: - TLV encoding

    func testTLVFrameEmpty() {
        let frame = ouraTLVFrame(tag: 0x10, payload: Data())
        XCTAssertEqual(Array(frame), [0x10, 0x00])
    }

    func testTLVFrameOneBytePayload() {
        let frame = ouraTLVFrame(tag: 0x2F, bytes: [0x01])
        XCTAssertEqual(Array(frame), [0x2F, 0x01, 0x01])
    }

    func testTLVFrameMultiBytePayload() {
        let frame = ouraTLVFrame(tag: 0x12, bytes: [0xAA, 0xBB, 0xCC])
        XCTAssertEqual(Array(frame), [0x12, 0x03, 0xAA, 0xBB, 0xCC])
    }

    func testTLVFrameDataAndBytesOverloadsMatch() {
        let bytes: [UInt8] = [0x01, 0x2B]
        let viaData  = ouraTLVFrame(tag: 0x2F, payload: Data(bytes))
        let viaBytes = ouraTLVFrame(tag: 0x2F, bytes: bytes)
        XCTAssertEqual(viaData, viaBytes)
    }

    // MARK: - Reassembler: single complete packet

    func testReassemblerSingleCompletePacket() {
        let asm = OuraReassembler()
        // TLV: tag=0x2F, len=3, body=[0x2C, 0x01, 0x02]
        asm.feed(Data([0x2F, 0x03, 0x2C, 0x01, 0x02]))
        let packets = asm.consume()
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(Array(packets[0]), [0x2F, 0x03, 0x2C, 0x01, 0x02])
    }

    func testReassemblerEmptyAfterConsume() {
        let asm = OuraReassembler()
        asm.feed(Data([0x10, 0x02, 0xAA, 0xBB]))
        _ = asm.consume()
        XCTAssertEqual(asm.consume().count, 0)
    }

    func testReassemblerFragmentedPacket() {
        let asm = OuraReassembler()
        // First BLE notification: just the tag + length
        asm.feed(Data([0x10, 0x04]))
        XCTAssertEqual(asm.consume().count, 0, "incomplete — no packet yet")
        // Second notification: the remaining 4 body bytes
        asm.feed(Data([0x01, 0x02, 0x03, 0x04]))
        let packets = asm.consume()
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(Array(packets[0]), [0x10, 0x04, 0x01, 0x02, 0x03, 0x04])
    }

    func testReassemblerTwoPacketsInOneNotification() {
        let asm = OuraReassembler()
        // Two back-to-back packets in a single notification
        asm.feed(Data([0x2F, 0x01, 0xAA,    // packet 1: tag=0x2F, len=1, body=[0xAA]
                       0x10, 0x02, 0xBB, 0xCC])) // packet 2: tag=0x10, len=2, body=[0xBB,0xCC]
        let packets = asm.consume()
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(Array(packets[0]), [0x2F, 0x01, 0xAA])
        XCTAssertEqual(Array(packets[1]), [0x10, 0x02, 0xBB, 0xCC])
    }

    func testReassemblerReset() {
        let asm = OuraReassembler()
        asm.feed(Data([0x10, 0x04, 0x01]))  // partial packet
        asm.reset()
        XCTAssertEqual(asm.consume().count, 0)
    }

    func testReassemblerZeroLengthPacket() {
        let asm = OuraReassembler()
        asm.feed(Data([0x0C, 0x00]))  // tag=0x0C (battery), len=0
        let packets = asm.consume()
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(Array(packets[0]), [0x0C, 0x00])
    }
}
