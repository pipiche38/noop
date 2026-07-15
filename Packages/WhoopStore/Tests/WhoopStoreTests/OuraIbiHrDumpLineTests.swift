import XCTest
@testable import WhoopStore

/// The banked-IBI → HR research-corpus JSONL line encoder. The line is asserted verbatim so the format is
/// pinned (any downstream reader can rely on the exact shape + key order).
final class OuraIbiHrDumpLineTests: XCTestCase {

    func testEncodesFixedShapeVerbatim() {
        let line = OuraIbiHrDumpLine.encode(
            deviceId: "oura-5C4C0BF8", ringTs: 5_691_839, utc: 1_783_400_728,
            iso: "2026-07-14T09:05:28Z", tag: 0x80, ibiMs: [812, 799, 830])
        XCTAssertEqual(line,
            "{\"schema\":1,\"deviceId\":\"oura-5C4C0BF8\",\"ringTs\":5691839," +
            "\"utc\":1783400728,\"iso\":\"2026-07-14T09:05:28Z\",\"tag\":128,\"ibiMs\":[812,799,830]}")
    }

    func testEmptyIbiIsEmptyArray() {
        let line = OuraIbiHrDumpLine.encode(
            deviceId: "d", ringTs: 1, utc: 2, iso: "x", tag: 0x44, ibiMs: [])
        XCTAssertTrue(line.hasSuffix("\"ibiMs\":[]}"))
    }

    func testEachLineIsValidJSON() throws {
        let line = OuraIbiHrDumpLine.encode(
            deviceId: "oura-ring", ringTs: 100, utc: 200, iso: "2026-07-14T00:00:00Z",
            tag: 0x6E, ibiMs: [1000, 950, 1010])
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual((obj?["ibiMs"] as? [Int])?.count, 3)
        XCTAssertEqual(obj?["tag"] as? Int, 0x6E)
        XCTAssertEqual(obj?["schema"] as? Int, OuraIbiHrDumpLine.schema)
        // HR = 60000/ibi is the intended reconstruction: 1000 ms → 60 bpm.
        XCTAssertEqual((obj?["ibiMs"] as? [Int])?.first.map { 60000 / $0 }, 60)
    }
}
