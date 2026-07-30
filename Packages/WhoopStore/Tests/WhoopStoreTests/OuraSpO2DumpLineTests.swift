import XCTest
@testable import WhoopStore

final class OuraSpO2DumpLineTests: XCTestCase {
    func testEncodeFixedKeyOrderAndValues() {
        let line = OuraSpO2DumpLine.encode(
            deviceId: "oura-2H3B2405003655", ringTs: 3_584_349, utc: 1_753_440_000,
            iso: "2026-07-30T09:09:01Z", unit: "raw", values: [95, 96, 96])
        XCTAssertEqual(line,
            "{\"schema\":1,\"deviceId\":\"oura-2H3B2405003655\",\"ringTs\":3584349,"
          + "\"utc\":1753440000,\"iso\":\"2026-07-30T09:09:01Z\",\"unit\":\"raw\",\"values\":[95,96,96]}")
    }

    func testEncodeEmptyValuesIsValidJSON() throws {
        let line = OuraSpO2DumpLine.encode(deviceId: "oura-x", ringTs: 1, utc: 2, iso: "i", unit: "dc_raw",
                                            values: [])
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schema"] as? Int, OuraSpO2DumpLine.schema)
        XCTAssertEqual(obj?["unit"] as? String, "dc_raw")
        XCTAssertEqual((obj?["values"] as? [Any])?.count, 0)
    }
}
