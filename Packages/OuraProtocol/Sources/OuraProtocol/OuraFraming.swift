import Foundation

// MARK: - TLV framing

/// Build a TLV-framed BLE write packet.
/// Format: [tag: u8][length: u8][payload…]
/// All multi-byte integers in the Oura protocol are little-endian.
public func ouraTLVFrame(tag: UInt8, payload: Data) -> Data {
    var frame = Data(capacity: 2 + payload.count)
    frame.append(tag)
    frame.append(UInt8(payload.count & 0xFF))
    frame.append(payload)
    return frame
}

/// Convenience overload for building a TLV frame from a byte array.
public func ouraTLVFrame(tag: UInt8, bytes: [UInt8]) -> Data {
    ouraTLVFrame(tag: tag, payload: Data(bytes))
}

// MARK: - Reassembler

/// Buffers BLE notification fragments and emits complete TLV packets.
///
/// The ring sends responses as TLV packets that may span multiple BLE notifications
/// when the response exceeds the negotiated MTU. Feed every `didUpdateValueFor` value
/// here; call `consume()` after each feed to drain any complete packets.
public final class OuraReassembler {

    private var buf = Data()

    public init() {}

    public func feed(_ data: Data) {
        buf.append(data)
    }

    /// Returns all complete TLV packets currently in the buffer, consuming them.
    public func consume() -> [Data] {
        var packets: [Data] = []
        while buf.count >= 2 {
            let length = Int(buf[1])
            let total  = 2 + length
            guard buf.count >= total else { break }
            packets.append(buf.subdata(in: 0..<total))
            buf.removeSubrange(0..<total)
        }
        return packets
    }

    /// Discard all buffered bytes — call on BLE disconnect.
    public func reset() {
        buf.removeAll(keepingCapacity: true)
    }
}
