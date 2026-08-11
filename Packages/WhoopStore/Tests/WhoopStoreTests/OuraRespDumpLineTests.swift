import XCTest
@testable import WhoopStore

final class OuraRespDumpLineTests: XCTestCase {
    /// Real shape from the 2026-08-07 overnight: hr 130/2 = 65 bpm, breath 115 × 0.125 = 14.375/min.
    func testEncodeFixedKeyOrderAndValues() {
        let line = OuraRespDumpLine.encode(
            deviceId: "oura-2H3B2405003655", ringTs: 3_584_349, utc: 1_753_440_000,
            iso: "2026-07-30T09:09:01Z", hr: 65, hrTrend: -0.0625, mzci: 1.5, dzci: 0.25,
            breath: 14.375, breathV: 0.5, motion: 3, state: 2, cv: 0.125)
        XCTAssertEqual(line,
            "{\"schema\":1,\"deviceId\":\"oura-2H3B2405003655\",\"ringTs\":3584349,"
          + "\"utc\":1753440000,\"iso\":\"2026-07-30T09:09:01Z\",\"hr\":65.0000,"
          + "\"hr_trend\":-0.0625,\"mzci\":1.5000,\"dzci\":0.2500,\"breath\":14.3750,"
          + "\"breath_variability\":0.5000,\"motion_count\":3,\"sleep_state\":2,\"cv\":0.1250}")
    }

    /// The wire multipliers are 0.5 / 0.0625 / 0.125, so 4 decimals must round-trip EVERY representable
    /// value exactly — a lossy format here would quietly corrupt the series this corpus exists to settle.
    func testFourDecimalsAreExactForEveryWireValue() throws {
        for raw in 0...255 {
            let breath = Double(raw) * 0.125
            let trend = Double(Int8(truncatingIfNeeded: raw)) * 0.0625
            let line = OuraRespDumpLine.encode(deviceId: "oura-x", ringTs: UInt32(raw + 1), utc: 2, iso: "i",
                                               hr: Double(raw) * 0.5, hrTrend: trend, mzci: 0, dzci: 0,
                                               breath: breath, breathV: 0, motion: 0, state: 0, cv: 0)
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertEqual(obj?["breath"] as? Double, breath, "breath lost precision at raw \(raw)")
            XCTAssertEqual(obj?["hr_trend"] as? Double, trend, "hr_trend lost precision at raw \(raw)")
        }
    }

    func testEncodeIsValidJSONWithTheSchemaTag() throws {
        let line = OuraRespDumpLine.encode(deviceId: "oura-x", ringTs: 1, utc: 2, iso: "i", hr: 0,
                                           hrTrend: 0, mzci: 0, dzci: 0, breath: 0, breathV: 0,
                                           motion: 0, state: 0, cv: 0)
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schema"] as? Int, OuraRespDumpLine.schema)
        XCTAssertEqual(obj?["deviceId"] as? String, "oura-x")
    }
}
