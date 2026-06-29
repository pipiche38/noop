import Foundation
import CommonCrypto
import Security

// MARK: - Key generation

/// Generate a cryptographically-random 16-byte auth key for a fresh ring pairing.
/// Store the returned bytes in the iOS/macOS Keychain bound to the device ID; never persist
/// elsewhere — it grants full protocol access to the ring.
public func generateOuraAuthKey() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
    return bytes
}

// MARK: - Nonce encryption

/// Encrypt a 15-byte nonce with AES-128/ECB/PKCS7 using the 16-byte auth key.
/// This is the Oura BLE authentication handshake (opcode 0x2D).
/// Returns 16 encrypted bytes on success, nil if `key` is not exactly 16 bytes.
public func encryptOuraNonce(_ nonce: [UInt8], key: [UInt8]) -> [UInt8]? {
    guard key.count == 16 else { return nil }

    // PKCS7-pad the nonce to a 16-byte block.
    let padLen = 16 - (nonce.count % 16)
    var padded = nonce
    padded.append(contentsOf: [UInt8](repeating: UInt8(padLen), count: padLen))

    var output = [UInt8](repeating: 0, count: 16)
    var written = 0
    let status = CCCrypt(
        CCOperation(kCCEncrypt),
        CCAlgorithm(kCCAlgorithmAES),
        CCOptions(kCCOptionECBMode),  // ECB: single block, no IV
        key, kCCKeySizeAES128,
        nil,                          // no IV for ECB mode
        padded, 16,
        &output, 16,
        &written
    )
    guard status == kCCSuccess else { return nil }
    return output
}

// MARK: - Key import (Phase B: co-exist with Oura app)

/// Parse a user-supplied 32-character hex string into a 16-byte auth key.
/// Used for key import: the user extracts their Oura app key via the open_oura CLI and
/// enters it here. NOOP then uses this key for auth without needing a factory reset.
/// Returns nil if the string is not exactly 32 valid hex characters.
public func ouraAuthKeyFromHex(_ hex: String) -> [UInt8]? {
    let clean = hex
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ":", with: "")
    guard clean.count == 32 else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(16)
    var idx = clean.startIndex
    while idx < clean.endIndex {
        let next = clean.index(idx, offsetBy: 2)
        guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
        bytes.append(byte)
        idx = next
    }
    return bytes.count == 16 ? bytes : nil
}

/// Render a 16-byte key as a lowercase hex string (for display / copy-to-clipboard).
public func ouraAuthKeyToHex(_ key: [UInt8]) -> String {
    key.map { String(format: "%02x", $0) }.joined()
}
