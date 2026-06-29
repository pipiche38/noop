import Foundation

// MARK: - Event envelope

/// A single decoded event from the Oura Ring historical event stream.
///
/// Raw event wire layout inside a batch response:
///   [tag: u8][length: u8][timestamp_decisec: u32 LE][body…]
/// The timestamp is in deciseconds (1/10-second units) since the ring's epoch.
/// Convert to Unix seconds: `unixEpoch + Double(timestampDecisec) / 10.0`
/// (the epoch offset is calibrated during `reqSyncTime`).
public struct OuraEvent: Sendable {
    public let tag: UInt8
    /// Timestamp in deciseconds since the ring's local epoch.
    public let timestampDecisec: UInt32
    /// Raw event body bytes (after the 4-byte timestamp prefix).
    public let body: Data

    /// Parse all events from the body of a batch response.
    /// `batchBody` is the payload after the `OuraEventBatchSummary` header bytes.
    public static func parseAll(from batchBody: Data) -> [OuraEvent] {
        var events: [OuraEvent] = []
        var offset = 0
        let bytes = Array(batchBody)
        while offset + 6 <= bytes.count {
            let tag    = bytes[offset]
            let length = Int(bytes[offset + 1])
            guard length >= 4, offset + 2 + length <= bytes.count else {
                offset += 2 + max(length, 0)
                continue
            }
            let ts: UInt32 =
                UInt32(bytes[offset + 2])
                | (UInt32(bytes[offset + 3]) << 8)
                | (UInt32(bytes[offset + 4]) << 16)
                | (UInt32(bytes[offset + 5]) << 24)
            let bodyStart = offset + 6
            let bodyEnd   = offset + 2 + length
            events.append(OuraEvent(
                tag: tag,
                timestampDecisec: ts,
                body: Data(bytes[bodyStart..<bodyEnd])
            ))
            offset = bodyEnd
        }
        return events
    }
}

// MARK: - Phase 1 event tags

public enum OuraEventTag: UInt8, Sendable {
    // HR / IBI
    case ibiPPG          = 0x44   // overnight IBI + PPG amplitude
    case greenIBIQuality = 0x80   // daytime IBI quality (bit-packed)
    // SpO2
    case spo2            = 0x6F   // SpO2 %
    case spo2RPi         = 0x77   // SpO2 R-ratio + perfusion index
    // Temperature
    case temperature     = 0x46   // skin temperature (centi-°C, signed)
    case temperature2    = 0x69   // secondary temperature probe (same encoding)
}

// MARK: - HR / IBI decoders

/// Decode tag 0x80 (green_ibi_quality) → BPM.
/// Body: repeating 2-byte pairs; low 7 bits of byte[0] = IBI in 10 ms units.
/// Returns the BPM from the first valid interval, nil if the body is empty or the IBI is implausible.
public func decodeHRFromGreenIBI(_ body: Data) -> Int? {
    guard !body.isEmpty else { return nil }
    let ibi10ms = Int(body[0] & 0x7F)
    guard ibi10ms > 0 else { return nil }
    let bpm = 60_000 / (ibi10ms * 10)
    return (20...250).contains(bpm) ? bpm : nil
}

/// Decode tag 0x44 (ibi_ppg) → mean BPM across all valid intervals in the body.
/// Body: repeating [ibi_ms: u16 LE][amplitude: u16 LE] — 4 bytes per sample.
public func decodeHRFromIBIPPG(_ body: Data) -> Int? {
    var total = 0
    var count = 0
    var offset = 0
    while offset + 4 <= body.count {
        let ibiMs = Int(body[offset]) | (Int(body[offset + 1]) << 8)
        if ibiMs > 0 {
            let bpm = 60_000 / ibiMs
            if (20...250).contains(bpm) { total += bpm; count += 1 }
        }
        offset += 4
    }
    return count > 0 ? total / count : nil
}

// MARK: - SpO2 decoders

/// Decode tag 0x6F (spo2) → SpO2 percentage.
/// Body: [spo2_pct: u8][dc_component: u16 LE]
public func decodeSpO2(_ body: Data) -> Double? {
    guard !body.isEmpty else { return nil }
    let pct = Double(body[0])
    return (70...100).contains(pct) ? pct : nil
}

/// Decode tag 0x77 (spo2_r_pi) → SpO2 percentage estimated from R-ratio.
/// Body: repeating [r_ratio: u16 BE][perfusion_index: u8] — 3-byte samples.
/// Uses the standard Beer-Lambert empirical approximation: SpO2 ≈ 110 − 25 × R.
public func decodeSpO2FromRatio(_ body: Data) -> Double? {
    guard body.count >= 3 else { return nil }
    // R-ratio is big-endian u16 in the first two bytes, scaled ÷ 1000.
    let rRaw = (UInt16(body[0]) << 8) | UInt16(body[1])
    guard rRaw > 0 else { return nil }
    let spo2 = 110.0 - 25.0 * (Double(rRaw) / 1000.0)
    return (70...100).contains(spo2) ? spo2 : nil
}

// MARK: - Temperature decoders

/// Decode tag 0x46 (temperature) → temperature in °C.
/// Body: [centi_celsius: i16 LE] — valid sensor range −40 to 85 °C.
public func decodeTemperatureCelsius(_ body: Data) -> Double? {
    guard body.count >= 2 else { return nil }
    let raw = Int16(bitPattern: UInt16(body[0]) | (UInt16(body[1]) << 8))
    let celsius = Double(raw) / 100.0
    return (-40...85).contains(celsius) ? celsius : nil
}

/// Decode tag 0x69 (temperature_2) — secondary temperature probe, same encoding as tag 0x46.
public func decodeTemperature2Celsius(_ body: Data) -> Double? {
    decodeTemperatureCelsius(body)
}
