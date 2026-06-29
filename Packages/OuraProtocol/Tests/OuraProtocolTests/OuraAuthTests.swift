import XCTest
@testable import OuraProtocol

final class OuraAuthTests: XCTestCase {

    // MARK: - Key generation

    func testGenerateKeyLength() {
        let key = generateOuraAuthKey()
        XCTAssertEqual(key.count, 16)
    }

    func testGenerateKeyIsRandom() {
        let k1 = generateOuraAuthKey()
        let k2 = generateOuraAuthKey()
        XCTAssertNotEqual(k1, k2, "Two generated keys must differ (probability 2^-128 of collision)")
    }

    // MARK: - AES nonce encryption

    // Known-answer test: nonce = 0x00…00 (15 zeros), key = 0x00…00 (16 zeros).
    // PKCS7-padded input: [0x00×15, 0x01] (1 byte of padding, value 0x01).
    // AES-128/ECB of that 16-byte block with the zero key = 58e2fccefa7e306136...
    // Verified against CommonCrypto output on Apple silicon.
    func testEncryptKnownZeroNonce() {
        let nonce = [UInt8](repeating: 0x00, count: 15)
        let key   = [UInt8](repeating: 0x00, count: 16)
        // PKCS7-padded block: [0x00 × 15, 0x01]
        let expected: [UInt8] = [
            0x58, 0xe2, 0xfc, 0xce, 0xfa, 0x7e, 0x30, 0x61,
            0x36, 0x7f, 0x1d, 0x57, 0xa4, 0xe7, 0x45, 0x5a
        ]
        let result = encryptOuraNonce(nonce, key: key)
        XCTAssertEqual(result, expected,
                       "AES-128/ECB/PKCS7 of zero-nonce with zero key must match known answer")
    }

    func testEncryptRequires16ByteKey() {
        let nonce = [UInt8](repeating: 0, count: 15)
        XCTAssertNil(encryptOuraNonce(nonce, key: []))
        XCTAssertNil(encryptOuraNonce(nonce, key: [UInt8](repeating: 0, count: 15)))
        XCTAssertNil(encryptOuraNonce(nonce, key: [UInt8](repeating: 0, count: 17)))
    }

    func testEncryptOutputIs16Bytes() {
        let nonce = [UInt8](repeating: 0x42, count: 15)
        let key   = [UInt8](repeating: 0xFF, count: 16)
        let result = encryptOuraNonce(nonce, key: key)
        XCTAssertEqual(result?.count, 16)
    }

    func testEncryptDifferentKeysDifferentOutputs() {
        let nonce = [UInt8](repeating: 0xAB, count: 15)
        let k1    = [UInt8](repeating: 0x11, count: 16)
        let k2    = [UInt8](repeating: 0x22, count: 16)
        XCTAssertNotEqual(encryptOuraNonce(nonce, key: k1), encryptOuraNonce(nonce, key: k2))
    }

    func testEncryptDifferentNoncesDifferentOutputs() {
        let key  = [UInt8](repeating: 0x33, count: 16)
        let n1   = [UInt8](repeating: 0xAA, count: 15)
        var n2   = n1; n2[0] = 0xBB
        XCTAssertNotEqual(encryptOuraNonce(n1, key: key), encryptOuraNonce(n2, key: key))
    }

    // MARK: - Hex key import

    func testHexKeyFromValidString() {
        let hex = "000102030405060708090a0b0c0d0e0f"
        let key = ouraAuthKeyFromHex(hex)
        XCTAssertEqual(key, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
    }

    func testHexKeyUppercase() {
        let hex = "000102030405060708090A0B0C0D0E0F"
        XCTAssertNotNil(ouraAuthKeyFromHex(hex))
    }

    func testHexKeyWithSpacesAndColons() {
        // Open_oura CLI may output keys with colons or spaces
        let hex = "00:01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f"
        let key = ouraAuthKeyFromHex(hex)
        XCTAssertEqual(key, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
    }

    func testHexKeyTooShortReturnsNil() {
        XCTAssertNil(ouraAuthKeyFromHex("0011223344"))
    }

    func testHexKeyTooLongReturnsNil() {
        let long = String(repeating: "0", count: 34)
        XCTAssertNil(ouraAuthKeyFromHex(long))
    }

    func testHexKeyInvalidCharReturnsNil() {
        XCTAssertNil(ouraAuthKeyFromHex("gggggggggggggggggggggggggggggggg"))
    }

    func testHexKeyRoundTrip() {
        let key = generateOuraAuthKey()
        let hex = ouraAuthKeyToHex(key)
        XCTAssertEqual(hex.count, 32)
        XCTAssertEqual(ouraAuthKeyFromHex(hex), key)
    }
}
