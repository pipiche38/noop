import Foundation

// MARK: - Auth commands

/// Request a nonce for authentication. Send after subscribing to the notify characteristic.
/// Ring responds on the notify char: [0x2F][len][0x2C][15 nonce bytes]
public func reqAuthNonce() -> Data {
    ouraTLVFrame(tag: 0x2F, bytes: [0x01, 0x2B])
}

/// Authenticate with the AES-128/ECB-encrypted nonce.
/// `encrypted` must be exactly 16 bytes (output of `encryptOuraNonce`).
/// Success response: [0x2F][len][0x2E][0x00]; failure: last byte non-zero (see `OuraAuthResult`).
public func reqAuthenticate(encrypted: [UInt8]) -> Data {
    var payload = Data([0x11, 0x2D])
    payload.append(contentsOf: encrypted)
    return ouraTLVFrame(tag: 0x2F, payload: payload)
}

/// Install the auth key onto a factory-reset ring. ONLY valid when the ring is in factory mode;
/// any other state returns an error response. `key` must be exactly 16 bytes.
public func reqSetAuthKey(key: [UInt8]) -> Data {
    var payload = Data([0x10])
    payload.append(contentsOf: key)
    return ouraTLVFrame(tag: 0x24, payload: payload)
}

// MARK: - Time sync

/// Synchronise the ring's real-time clock. Call after a successful auth handshake.
/// - Parameters:
///   - unixSecs: Current Unix timestamp in whole seconds.
///   - tzHalfHours: Timezone offset in 30-minute steps (e.g. UTC+2 → 4, UTC-5 → -10 as UInt8 wrap).
public func reqSyncTime(unixSecs: UInt64, tzHalfHours: UInt8) -> Data {
    var payload = Data()
    withUnsafeBytes(of: unixSecs.littleEndian) { payload.append(contentsOf: $0) }
    payload.append(tzHalfHours)
    return ouraTLVFrame(tag: 0x12, payload: payload)
}

// MARK: - Feature modes

public enum OuraFeature: UInt8, Sendable {
    case backgroundDFU   = 0x00
    case researchData    = 0x01
    case daytimeHR       = 0x02
    case exerciseHR      = 0x03
    case spo2            = 0x04
    case restingHR       = 0x08
    case chargingControl = 0x0E
}

public enum OuraFeatureMode: UInt8, Sendable {
    case off           = 0x00
    case automatic     = 0x01
    case requested     = 0x02
    /// Streams IBI in real time; BPM = 60_000 / ibi_ms. Requires active connection.
    case connectedLive = 0x03
}

/// Set the operating mode for a specific ring feature.
public func reqSetFeatureMode(feature: OuraFeature, mode: OuraFeatureMode) -> Data {
    ouraTLVFrame(tag: 0x2F, bytes: [0x22, feature.rawValue, mode.rawValue])
}

// MARK: - Event drain

/// Fetch a batch of historical events starting from `startDeciseconds` (inclusive).
/// The cursor is in deciseconds (1/10-second units). Pass 0 for a full re-sync from the earliest
/// stored event. Repeat until `OuraEventBatchSummary.bytesLeft == 0`.
public func reqGetEvent(startDeciseconds: UInt32) -> Data {
    var payload = Data()
    withUnsafeBytes(of: startDeciseconds.littleEndian) { payload.append(contentsOf: $0) }
    payload.append(0x08)   // maxEvents per response (8)
    withUnsafeBytes(of: Int32(-1).littleEndian) { payload.append(contentsOf: $0) }  // flags: all types
    return ouraTLVFrame(tag: 0x10, payload: payload)
}

// MARK: - Response parsers

/// The application-layer outcome of an `reqAuthenticate` response.
public enum OuraAuthResult: UInt8, Equatable, Sendable {
    case success                    = 0x00
    case authenticationError        = 0x01
    case inFactoryReset             = 0x02
    case notOriginalOnboardedDevice = 0x03
    case unknown                    = 0xFF

    public init(byte: UInt8) {
        self = OuraAuthResult(rawValue: byte) ?? .unknown
    }
}

/// Extract the `OuraAuthResult` from an authenticate response packet.
/// Expected packet layout: [0x2F][len][0x2E][result: u8]
public func parseAuthResult(_ packet: Data) -> OuraAuthResult? {
    guard packet.count >= 4,
          packet[0] == 0x2F,
          packet[2] == 0x2E else { return nil }
    return OuraAuthResult(byte: packet[3])
}

/// Extract the 15-byte nonce from a nonce response packet.
/// Expected packet layout: [0x2F][len][0x2C][15 nonce bytes]
public func parseNonce(_ packet: Data) -> [UInt8]? {
    guard packet.count >= 18,
          packet[0] == 0x2F,
          packet[2] == 0x2C else { return nil }
    return Array(packet[3..<18])
}

/// Metadata returned with each event batch.
/// The `bytesLeft` field drives the drain loop: keep calling `reqGetEvent` while it is > 0.
public struct OuraEventBatchSummary: Sendable {
    public let eventsInBatch: UInt8
    public let bytesLeft: UInt32

    /// Parse from the ring's response to `reqGetEvent`.
    /// Expected layout: [0x10][len][events_in_batch: u8][bytes_left: u32 LE][…]
    public init?(packet: Data) {
        guard packet.count >= 7, packet[0] == 0x10 else { return nil }
        eventsInBatch = packet[2]
        bytesLeft = Data(packet[3..<7]).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }
}
