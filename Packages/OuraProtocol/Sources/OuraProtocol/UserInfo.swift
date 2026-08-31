import Foundation

// User-info setters (opcode 0x20) and their 0x21 replies.
//
// EXPERIMENTAL / QUARANTINED. These are the only builders in this package that write user data to
// the ring, and nothing in OuraDriver's flow produces them - they exist to answer one question:
// does writing 0x20 change what tag 0x5c reports? See OuraUserInfoWrite for why that is open.
//
// Platform-pure value types. Facts cited per OURA_PROTOCOL.md; wire shapes per [open_oura-cheat]
// (docs/horizon-ring3-protocol-cheatsheet.md), which records these five setters as tested-success on
// a Ring 3 - writing ZEROS. No published capture writes a real value, which is exactly the gap.

/// The `0x20` user-info fields, keyed by the `type` byte the ring echoes back in its `0x21` reply.
///
/// Value widths are taken from the tested request shapes in [open_oura-cheat]: gender/unit carry two
/// value bytes, height/weight three, date-of-birth nine. The width is a FACT (the ring acked those
/// exact lengths); the *encoding* inside those bytes is not - see `OuraUserInfoWrite`.
public enum OuraUserInfoField: UInt8, CaseIterable, Sendable {
    case gender = 0x02
    case height = 0x03
    case weight = 0x04
    case dateOfBirth = 0x05
    case unit = 0x06

    /// Number of value bytes that follow the type byte, per the acked shapes in [open_oura-cheat].
    public var valueByteCount: Int {
        switch self {
        case .gender, .unit: return 2
        case .height, .weight: return 3
        case .dateOfBirth: return 9
        }
    }

    /// The label used in the strap log. Never carries the value itself.
    public var label: String {
        switch self {
        case .gender: return "gender"
        case .height: return "height"
        case .weight: return "weight"
        case .dateOfBirth: return "dob"
        case .unit: return "unit"
        }
    }
}

/// The ring's `0x21` reply to a `0x20` write: `21 02 <type> <result>`. `result == 0` is success on
/// every shape [open_oura-cheat] recorded.
public struct OuraUserInfoAck: Equatable, Sendable {
    public let field: OuraUserInfoField
    public let result: UInt8
    public var isSuccess: Bool { result == 0 }
    public init(field: OuraUserInfoField, result: UInt8) { self.field = field; self.result = result }
}

/// Builders for the `0x20` user-info setters, plus the encoding candidate that maps a NOOP user
/// profile onto them.
///
/// ⚠️ **The value encoding is a CANDIDATE, not a decoded fact.** Every published `0x20` write sets
/// its field to zero, so no capture pins down the units, scale, or byte order of a non-zero value.
/// What is known: tag `0x5c` reports height and weight as **single bytes** reading 176 and 75 - i.e.
/// whole cm and whole kg - so a little-endian integer in cm/kg is the encoding most likely to land in
/// those bytes. That is a hypothesis this type exists to TEST, and `writeThenVerify` documents the
/// procedure. Do not present a write as having "set the profile" until a subsequent `0x5c` read shows
/// the value moved.
public enum OuraUserInfoWrite {
    /// Build a raw `0x20` write: `20 <len> <type> <value…>`, `len` = 1 + the field's value width.
    ///
    /// Throws if `value` is not exactly `field.valueByteCount` bytes - the ring acked those specific
    /// lengths and a different one is an untested shape.
    public static func command(_ field: OuraUserInfoField, value: [UInt8]) throws -> OuraCommand {
        guard value.count == field.valueByteCount else {
            throw OuraUserInfoError.wrongValueWidth(field: field,
                                                   expected: field.valueByteCount,
                                                   got: value.count)
        }
        let len = UInt8(1 + value.count)
        return OuraCommand(label: "EXPERIMENT_set_user_\(field.label)",
                           bytes: [0x20, len, field.rawValue] + value)
    }

    /// The zero/"empty" writes recorded as tested-success in [open_oura-cheat]. Useful as the restore
    /// step after an experiment, and as the golden shapes the tests pin.
    public static func clear(_ field: OuraUserInfoField) -> OuraCommand {
        // Safe by construction: the width comes from the field itself, so `command` cannot throw.
        (try? command(field, value: [UInt8](repeating: 0, count: field.valueByteCount)))
            ?? OuraCommand(label: "EXPERIMENT_set_user_\(field.label)", bytes: [])
    }

    /// Encode an unsigned integer little-endian into exactly `width` bytes.
    ///
    /// Throws if the value does not fit, rather than silently truncating - a truncated anthropometric
    /// write would land a plausible-looking wrong number on the ring.
    public static func encodeLE(_ value: UInt32, width: Int) throws -> [UInt8] {
        let maxValue: UInt64 = (UInt64(1) << (8 * UInt64(width))) - 1
        guard UInt64(value) <= maxValue else {
            throw OuraUserInfoError.valueOutOfRange(value: value, width: width)
        }
        return (0..<width).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) }
    }

    /// Height in whole centimetres, little-endian across the field's three bytes. CANDIDATE encoding.
    public static func height(cm: UInt32) throws -> OuraCommand {
        try command(.height, value: try encodeLE(cm, width: OuraUserInfoField.height.valueByteCount))
    }

    /// Weight in whole kilograms, little-endian across the field's three bytes. CANDIDATE encoding.
    ///
    /// Whole kg is the candidate because `0x5c` byte 1 reads 75 on a ring whose firmware default is
    /// documented as 75 kg. If the ring instead wants grams, this write lands 62 g and `0x5c` will not
    /// move to 62 - which is precisely the outcome that would falsify the candidate.
    public static func weight(kg: UInt32) throws -> OuraCommand {
        try command(.weight, value: try encodeLE(kg, width: OuraUserInfoField.weight.valueByteCount))
    }

    /// Gender as the code `0x5c` byte 2 uses: 0 male, 1 female, anything else unspecified
    /// [open_oura-evt]. CANDIDATE encoding - that mapping is read off the *event* decoder, and nothing
    /// proves the setter shares it.
    public static func gender(_ code: UInt8) throws -> OuraCommand {
        try command(.gender, value: try encodeLE(UInt32(code), width: OuraUserInfoField.gender.valueByteCount))
    }

    /// Map NOOP's `sex` string onto the `0x5c` gender code. Anything that is not male/female is
    /// "unspecified", which is the value `bmr_schofield` documents as the both-sexes average
    /// [open_oura-evt] - so nonbinary and unset both land on the ring's own neutral path.
    public static func genderCode(forSex sex: String) -> UInt8 {
        switch sex.lowercased() {
        case "male": return 0
        case "female": return 1
        default: return 2
        }
    }

    /// ⚠️ **There is no `0x20` age setter.** `0x5c` byte 0 reports age in years, but the only related
    /// write is date-of-birth (`type 5`, nine value bytes) and no capture shows its layout. So of the
    /// four `0x5c` fields, three have a plausible direct setter and **age does not**. This returns nil
    /// rather than guessing a nine-byte DOB encoding; fill it in only once a capture pins the shape.
    public static func dateOfBirthCommand(year: Int, month: Int, day: Int) -> OuraCommand? { nil }
}

/// Errors from building a user-info write. Both are programmer errors caught before any byte reaches
/// the ring.
public enum OuraUserInfoError: Error, Equatable, Sendable {
    case wrongValueWidth(field: OuraUserInfoField, expected: Int, got: Int)
    case valueOutOfRange(value: UInt32, width: Int)
}

/// Parse a `0x21` user-info reply. Returns nil for anything that is not exactly `21 02 <type> <res>`
/// with a known type, so an unrelated `0x21` frame is never reported as an ack.
public func parseOuraUserInfoAck(_ bytes: [UInt8]) -> OuraUserInfoAck? {
    guard bytes.count == 4, bytes[0] == 0x21, bytes[1] == 0x02,
          let field = OuraUserInfoField(rawValue: bytes[2]) else { return nil }
    return OuraUserInfoAck(field: field, result: bytes[3])
}
