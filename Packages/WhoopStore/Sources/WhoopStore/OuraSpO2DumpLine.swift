import Foundation

/// Pure, deterministic encoder for ONE line of the Oura SpO2 research corpus — a diagnostic JSONL
/// sidecar, NOT a datastore row.
///
/// WHY a sidecar even though SpO2 (`0x6F`/`0x7B`/`0x77`) is Tier-A and already lands in the durable
/// `spo2Sample` table via `OuraStreamMapping`: the stored value is the decoder's raw unit (`"raw"` /
/// `"dc_raw"`), not a calibrated percentage — nobody has yet worked out (or validated against a
/// reference) the raw→% formula. This corpus exists purely so the raw samples can be studied offline
/// while that calibration work happens, without re-deriving them from `oura-raw.jsonl` by hand each
/// time. Never feeds scoring beyond what `OuraStreamMapping` already does, and is safe to delete.
/// Parallels `OuraCvaPpgDumpLine` / `OuraActivityDumpLine` / `OuraMotionDumpLine`.
public enum OuraSpO2DumpLine {
    /// Bump when the record shape changes so a downstream reader can branch on `schema`.
    public static let schema = 1

    /// One JSONL record (NO trailing newline — the writer adds it). `deviceId` is a controlled registry id
    /// (e.g. `oura-<serial>`) and `iso`/`unit` are app-generated, so none need JSON string-escaping here.
    ///   - ringTs: the record's raw ring-clock timestamp (the dedup key: strictly increases per record).
    ///   - utc:    the anchored wall-clock (unix seconds) for the record envelope.
    ///   - iso:    human-readable UTC of `utc` (convenience for eyeballing).
    ///   - unit:   the decoder's own scale tag (`"raw"` for 0x6F/0x7B, `"dc_raw"` for 0x77) — see
    ///             `OuraSpO2.unit`. Uniform across `values` (one record, one decoder, one tag).
    ///   - values: every sample this ONE record contributed, in wire order (0x6F/0x77 can carry several
    ///             samples per record, all stamped with the record's single `ringTs` — same batching
    ///             `OuraCvaPpgDumpLine.values` uses for the same reason).
    public static func encode(deviceId: String, ringTs: UInt32, utc: Int, iso: String, unit: String,
                               values: [Int]) -> String {
        let valuesStr = values.map { String($0) }.joined(separator: ",")
        return "{\"schema\":\(schema),\"deviceId\":\"\(deviceId)\",\"ringTs\":\(ringTs),"
             + "\"utc\":\(utc),\"iso\":\"\(iso)\",\"unit\":\"\(unit)\",\"values\":[\(valuesStr)]}"
    }
}
