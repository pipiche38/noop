import Foundation

/// Pure, deterministic encoder for ONE line of the Oura sleep-period (0x6A `sleep_period_info`) research
/// corpus — a diagnostic JSONL sidecar, NOT a datastore row.
///
/// WHY a sidecar, and why THIS tag needs one more than the others: `0x6A` byte4 (`breath` / 8.0) is the
/// only respiratory-rate channel the ring is known to send us, and validating it against WHOOP's own RR
/// (the #194 bar: it must TRACK a varying input over ≥ 2 nights) is the last open question on the Oura
/// respiration path. Today the tag is log-only — decoded, printed to the strap log, then dropped
/// (`OuraStreamMapping` drops `.sleepPeriodInfo` unconditionally) — so the NOOP half of that comparison
/// exists ONLY inside the strap log. Seven paired nights have now failed to produce a ledger row, and on
/// three of them the reason was mechanical rather than scientific: the app restarted after wake and the
/// overnight log was gone before the bundle was exported. A morning-only bundle can never supply the
/// number. This corpus fixes that mechanically — a tiny (~1 record / 5 min ⇒ a few hundred lines a night),
/// append-only, deduped file that survives independently of the strap log's rotation and of the raw
/// sidecar's size cap.
///
/// It does NOT promote the tag: still never persisted to a table, still never scored, still not surfaced
/// as a respiratory rate. Naming a field is not validating it, and `breath` sits at 13.3–14.75/min — well
/// inside the physiological clamp — so "it looks plausible" is not evidence either. This file exists so
/// the SERIES can be compared against ground truth offline, which is the only thing that can settle it.
/// Safe to delete; nothing reads it back.
///
/// FORMAT: newline-delimited JSON (JSONL), one record per line, append-only, FIXED key order so it is
/// stable and testable byte-for-byte. Parallels `OuraMotionDumpLine` / `OuraSpO2DumpLine`.
public enum OuraRespDumpLine {
    /// Bump when the record shape changes so a downstream reader can branch on `schema`.
    public static let schema = 1

    /// Fixed-precision so a line is byte-stable across platforms and locales. The 0x6A multipliers are
    /// 0.5 / 0.0625 / 0.125, so every real value is exactly representable in 4 decimals — this rounds
    /// nothing that the wire actually carries.
    private static func num(_ v: Double) -> String { String(format: "%.4f", v) }

    /// One JSONL record (NO trailing newline — the writer adds it). `deviceId` is a controlled registry id
    /// (e.g. `oura-<serial>`) and `iso` is app-generated, so neither needs JSON string-escaping here.
    ///   - ringTs:  the record's raw ring-clock timestamp (the dedup key: strictly increases per record).
    ///   - utc:     the anchored wall-clock (unix seconds) for the record envelope.
    ///   - iso:     human-readable UTC of `utc` (convenience for eyeballing).
    ///   - hr:      `average_hr`, the ring's OWN per-window mean heart rate (wire u8 × 0.5).
    ///   - hrTrend: `hr_trend`, the only SIGNED field in the body (wire s8 × 0.0625).
    ///   - mzci / dzci / cv: the remaining third-party-named scalars, carried verbatim so the corpus does
    ///             not have to be re-derived if one of them turns out to matter.
    ///   - breath:  `breath` — THE FIELD UNDER TEST (wire u8 × 0.125), breaths per minute.
    ///   - breathV: `breath_variability`.
    ///   - motion:  `motion_count` for the window.
    ///   - state:   the ring's own sleep-state code for the window.
    public static func encode(deviceId: String, ringTs: UInt32, utc: Int, iso: String,
                              hr: Double, hrTrend: Double, mzci: Double, dzci: Double,
                              breath: Double, breathV: Double, motion: Int, state: Int,
                              cv: Double) -> String {
        return "{\"schema\":\(schema),\"deviceId\":\"\(deviceId)\",\"ringTs\":\(ringTs),"
             + "\"utc\":\(utc),\"iso\":\"\(iso)\",\"hr\":\(num(hr)),\"hr_trend\":\(num(hrTrend)),"
             + "\"mzci\":\(num(mzci)),\"dzci\":\(num(dzci)),\"breath\":\(num(breath)),"
             + "\"breath_variability\":\(num(breathV)),\"motion_count\":\(motion),"
             + "\"sleep_state\":\(state),\"cv\":\(num(cv))}"
    }
}
