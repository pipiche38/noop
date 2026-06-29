import XCTest
@testable import OuraProtocol

final class OuraEventsTests: XCTestCase {

    // MARK: - HR / IBI decoding

    func testGreenIBIQualityNormalHR() {
        // IBI = 0x4B = 75 (10 ms units) → 750 ms → 80 BPM
        let body = Data([0x4B, 0x00])
        XCTAssertEqual(decodeHRFromGreenIBI(body), 80)
    }

    func testGreenIBIQualityLowHR() {
        // IBI = 0x78 = 120 (10 ms units) → 1200 ms → 50 BPM
        let body = Data([0x78, 0x00])
        XCTAssertEqual(decodeHRFromGreenIBI(body), 50)
    }

    func testGreenIBIQualityZeroReturnsNil() {
        let body = Data([0x00, 0x00])
        XCTAssertNil(decodeHRFromGreenIBI(body))
    }

    func testGreenIBIQualityEmptyBodyReturnsNil() {
        XCTAssertNil(decodeHRFromGreenIBI(Data()))
    }

    func testGreenIBIQualityMasksHighBit() {
        // 0x80 | 0x4B = 0xCB, low 7 bits = 0x4B = 75 → 80 BPM
        let body = Data([0xCB, 0x00])
        XCTAssertEqual(decodeHRFromGreenIBI(body), 80)
    }

    func testIBIPPGMeanBPM() {
        // Two samples: IBI = 600 ms → 100 BPM; IBI = 1000 ms → 60 BPM. Mean = 80.
        var body = Data()
        body.append(contentsOf: [0x58, 0x02, 0x00, 0x00])  // 0x0258 = 600 ms LE
        body.append(contentsOf: [0xE8, 0x03, 0x00, 0x00])  // 0x03E8 = 1000 ms LE
        XCTAssertEqual(decodeHRFromIBIPPG(body), 80)
    }

    func testIBIPPGSkipsZeroIBI() {
        var body = Data()
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // zero IBI → skip
        body.append(contentsOf: [0xE8, 0x03, 0x00, 0x00])  // 1000 ms → 60 BPM
        XCTAssertEqual(decodeHRFromIBIPPG(body), 60)
    }

    func testIBIPPGEmptyBodyReturnsNil() {
        XCTAssertNil(decodeHRFromIBIPPG(Data()))
    }

    func testIBIPPGImplausibleBPMExcluded() {
        // IBI = 10 ms → 6000 BPM — implausible, must be excluded
        var body = Data()
        body.append(contentsOf: [0x0A, 0x00, 0x00, 0x00])  // 10 ms LE
        body.append(contentsOf: [0xE8, 0x03, 0x00, 0x00])  // 1000 ms → 60 BPM
        XCTAssertEqual(decodeHRFromIBIPPG(body), 60)
    }

    // MARK: - SpO2 decoding

    func testDecodeSpO2Normal() {
        // SpO2 = 98%
        XCTAssertEqual(decodeSpO2(Data([0x62, 0x00, 0x00])), 98.0)
    }

    func testDecodeSpO2Minimum() {
        XCTAssertEqual(decodeSpO2(Data([70, 0x00, 0x00])), 70.0)
    }

    func testDecodeSpO2TooLowReturnsNil() {
        XCTAssertNil(decodeSpO2(Data([50])))
    }

    func testDecodeSpO2TooHighReturnsNil() {
        XCTAssertNil(decodeSpO2(Data([101])))
    }

    func testDecodeSpO2EmptyReturnsNil() {
        XCTAssertNil(decodeSpO2(Data()))
    }

    func testDecodeSpO2FromRatioTypical() {
        // R = 0.5 → SpO2 ≈ 110 - 25 × 0.5 = 97.5
        // rRaw = 500 = 0x01F4, big-endian bytes: [0x01, 0xF4]
        let body = Data([0x01, 0xF4, 0x20])  // [r_hi, r_lo, pi]
        let spo2 = decodeSpO2FromRatio(body)
        XCTAssertNotNil(spo2)
        XCTAssertEqual(spo2!, 97.5, accuracy: 0.001)
    }

    func testDecodeSpO2FromRatioZeroReturnsNil() {
        XCTAssertNil(decodeSpO2FromRatio(Data([0x00, 0x00, 0x00])))
    }

    func testDecodeSpO2FromRatioTooShortReturnsNil() {
        XCTAssertNil(decodeSpO2FromRatio(Data([0x01, 0xF4])))
    }

    // MARK: - Temperature decoding

    func testDecodeTemperature37C() {
        // 37.0 °C = 3700 centi-°C = 0x0E74, LE: [0x74, 0x0E]
        let body = Data([0x74, 0x0E])
        XCTAssertEqual(decodeTemperatureCelsius(body)!, 37.0, accuracy: 0.001)
    }

    func testDecodeTemperatureNegative() {
        // −10.5 °C = −1050 = 0xFBE6 as i16 LE: [0xE6, 0xFB]
        let raw = Int16(-1050)
        let lo = UInt8(bitPattern: Int8(truncatingIfNeeded: raw))
        let hi = UInt8(bitPattern: Int8(truncatingIfNeeded: raw >> 8))
        let body = Data([lo, hi])
        XCTAssertEqual(decodeTemperatureCelsius(body)!, -10.5, accuracy: 0.001)
    }

    func testDecodeTemperatureOutOfRangeHigh() {
        // 90 °C = 9000 = 0x2328 LE: [0x28, 0x23]
        XCTAssertNil(decodeTemperatureCelsius(Data([0x28, 0x23])))
    }

    func testDecodeTemperatureOutOfRangeLow() {
        // −50 °C = −5000 = 0xEC78 as i16 LE: [0x78, 0xEC]
        XCTAssertNil(decodeTemperatureCelsius(Data([0x78, 0xEC])))
    }

    func testDecodeTemperatureTooShortReturnsNil() {
        XCTAssertNil(decodeTemperatureCelsius(Data([0x74])))
    }

    func testDecodeTemperature2SameEncodingAsTemperature() {
        let body = Data([0x74, 0x0E])
        XCTAssertEqual(decodeTemperatureCelsius(body), decodeTemperature2Celsius(body))
    }

    // MARK: - Event envelope parsing

    func testParseEventEnvelope() {
        // Single event: tag=0x46, len=6, ts=100 decisec LE, body=[0x74,0x0E]
        // ts=100 = 0x00000064 LE: [0x64,0x00,0x00,0x00]
        let raw = Data([0x46, 0x06, 0x64, 0x00, 0x00, 0x00, 0x74, 0x0E])
        let events = OuraEvent.parseAll(from: raw)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].tag, 0x46)
        XCTAssertEqual(events[0].timestampDecisec, 100)
        XCTAssertEqual(Array(events[0].body), [0x74, 0x0E])
    }

    func testParseMultipleEvents() {
        var raw = Data()
        // Event 1: tag=0x46, len=4, ts=10, body=[]
        raw.append(contentsOf: [0x46, 0x04, 0x0A, 0x00, 0x00, 0x00])
        // Event 2: tag=0x80, len=6, ts=20, body=[0x4B,0x00]
        raw.append(contentsOf: [0x80, 0x06, 0x14, 0x00, 0x00, 0x00, 0x4B, 0x00])
        let events = OuraEvent.parseAll(from: raw)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].tag, 0x46)
        XCTAssertEqual(events[0].timestampDecisec, 10)
        XCTAssertEqual(events[1].tag, 0x80)
        XCTAssertEqual(events[1].timestampDecisec, 20)
        XCTAssertEqual(Array(events[1].body), [0x4B, 0x00])
    }

    func testParseEmptyBatchBodyReturnsNone() {
        XCTAssertEqual(OuraEvent.parseAll(from: Data()).count, 0)
    }

    func testParseTruncatedEventSkipped() {
        // Declares length=10 but only 4 bytes remain
        let raw = Data([0x46, 0x0A, 0x01, 0x00, 0x00, 0x00])
        XCTAssertEqual(OuraEvent.parseAll(from: raw).count, 0)
    }
}
