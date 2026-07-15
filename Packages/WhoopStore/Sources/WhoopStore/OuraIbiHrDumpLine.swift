import Foundation

/// Pure, deterministic encoder for ONE line of the Oura banked-IBI → HR research corpus — a diagnostic
/// JSONL sidecar, NOT a datastore row. Sibling of `OuraActivityDumpLine`.
///
/// WHY: the ring's HISTORY offload carries per-beat inter-beat intervals (IBI, ms) in the green-IBI
/// records (0x80 `green_ibi_quality`, plus 0x60/0x6E/0x44), already quality-gated by the decoders. HR is
/// trivially `60000 / ibiMs`, so those banked IBIs are a per-beat HEART-RATE history — recoverable across
/// the disconnects where the live-push HR is lost (e.g. a walk out of BLE range), and densest overnight
/// where the ring is still. open_oura feeds exactly this (`hr_bpm` from the 0x80 record) into its activity
/// model. NOOP already decodes these IBIs for HRV but never assembles an HR history from them; this corpus
/// captures the raw banked IBIs so we can measure, OFFLINE, how dense/plausible that HR history is during
/// activity vs sleep BEFORE any of it is wired into scoring (validate-against-the-artifact / #960 posture —
/// instrumentation only, never a durable/scoring row, safe to delete).
///
/// FORMAT: newline-delimited JSON (JSONL), one record per line, append-only, hand-built in a FIXED key
/// order so it is stable + testable byte-for-byte. `ibiMs` is the verbatim per-beat interval list for the
/// record (all beats in one history record share its `ringTs`); a reader recomputes HR = 60000 / ibiMs and
/// bins per minute. Raw IBIs are kept (not a pre-averaged HR) so the offline analysis owns the filtering.
public enum OuraIbiHrDumpLine {
    /// Bump when the record shape changes so a downstream reader can branch on `schema`.
    public static let schema = 1

    /// One JSONL record (NO trailing newline — the writer adds it). `deviceId` is a controlled registry id
    /// (e.g. `oura-<uuid>`) and `iso` is app-generated, so neither needs JSON string-escaping here.
    ///   - ringTs: the record's raw ring-clock timestamp (the dedup key: strictly increases per record).
    ///   - utc:    the anchored wall-clock (unix seconds) for the record envelope — the REAL beat time.
    ///   - iso:    human-readable UTC of `utc` (convenience for eyeballing).
    ///   - tag:    the source event tag these beats decoded from (0x80 green-IBI, 0x60/0x44 ibi+amp, 0x6E
    ///             spo2-IBI), as a decimal int — lets the offline study separate clean vs noisy streams.
    ///   - ibiMs:  the record's per-beat inter-beat intervals in milliseconds (quality-gated by the decoder).
    public static func encode(deviceId: String, ringTs: UInt32, utc: Int, iso: String,
                              tag: Int, ibiMs: [Int]) -> String {
        let ibiStr = ibiMs.map { String($0) }.joined(separator: ",")
        return "{\"schema\":\(schema),\"deviceId\":\"\(deviceId)\",\"ringTs\":\(ringTs),"
             + "\"utc\":\(utc),\"iso\":\"\(iso)\",\"tag\":\(tag),\"ibiMs\":[\(ibiStr)]}"
    }
}
