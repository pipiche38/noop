import Foundation

// ActivityEstimate: aggregate the ring's 0x50 activity_info MET stream into a clearly-labeled activity
// estimate (active minutes / MET-minutes / active energy). This is the HONEST activity metric — it is
// derived only from the already-decoded MET samples (OuraDecoders.decodeActivityInfo), never from a
// minted step count. The MET decode formula is third-party (see OuraActivityInfo) and NOT ground-truth-
// validated, so everything here stays Tier B: the app surfaces it as an estimate to validate against
// WHOOP active-kcal / Apple Health active energy, and it is never folded into scoring as truth.
//
// Platform-pure, database-free, value types only (builds on Linux). Facts per OURA_PROTOCOL.md s6.13.

/// A MET-derived activity estimate for a set of 0x50 samples (one window, one day, whatever the caller
/// buckets). Every field is an ESTIMATE; the two energy fields are nil when no body mass is supplied.
public struct OuraActivityEstimate: Equatable, Sendable {
    /// Number of MET samples aggregated (each 0x50 record contributes `met.count` of them).
    public let sampleCount: Int
    /// The per-sample epoch length assumed for the minute/energy totals. This is the ONE calibration
    /// unknown (the ring's raw MET cadence is unconfirmed); validating the totals against WHOOP / Apple
    /// Health is how it gets pinned. Carried on the estimate so a log line is self-describing.
    public let epochSeconds: Double
    /// Mean MET across all samples (cadence-independent — the cleanest cross-check value).
    public let meanMET: Double
    /// Peak MET across all samples (cadence-independent).
    public let maxMET: Double
    /// Σ metᵢ × epochMinutes — standard MET-minutes of activity.
    public let metMinutes: Double
    /// Minutes whose MET ≥ `moderateThresholdMET` (default 3.0 = moderate) — a "how long were you active"
    /// figure, = (count of qualifying samples) × epochMinutes.
    public let activeMinutes: Double
    /// Estimated ABOVE-RESTING energy: Σ max(metᵢ − 1, 0) × massKg × epochHours (kcal). This is the
    /// "active energy" convention WHOOP / Apple Health report (it excludes the 1-MET basal floor). nil
    /// without body mass.
    public let estActiveKcal: Double?
    /// Estimated GROSS energy: Σ metᵢ × massKg × epochHours (kcal), basal included. nil without body mass.
    public let estTotalKcal: Double?
    // NO STEP FIELD — REMOVED 2026-08-07, and it must not come back. See the note on
    // `OuraActivityEstimator` for the falsifier that killed it. The ring exposes no step count NOOP can
    // decode (`0x7E`/`0x7F` are model FEATURES, ground-truth-refuted 2026-08-01, OURA_PROTOCOL.md §6.13),
    // and MET cannot substitute for one: it measures EXERTION, not gait.

    public init(sampleCount: Int, epochSeconds: Double, meanMET: Double, maxMET: Double,
                metMinutes: Double, activeMinutes: Double, estActiveKcal: Double?, estTotalKcal: Double?) {
        self.sampleCount = sampleCount
        self.epochSeconds = epochSeconds
        self.meanMET = meanMET
        self.maxMET = maxMET
        self.metMinutes = metMinutes
        self.activeMinutes = activeMinutes
        self.estActiveKcal = estActiveKcal
        self.estTotalKcal = estTotalKcal
    }
}

/// Pure MET-stream aggregation. No database, no CoreBluetooth, no clock — the caller decides which
/// samples belong to the window/day (using the UTC anchor) and passes them in.
public enum OuraActivityEstimator {
    // MARK: - Why there is no step estimate here (read before adding one)
    //
    // A `stepsPerActiveMinute` constant and a `maxTrustedActiveMinutes` guard used to live here, turning
    // active minutes into a "walking-equivalent" step figure. **Both were REMOVED on 2026-08-07 because a
    // controlled falsifier refuted the model outright.** The history is kept because the idea is tempting
    // and will be re-proposed:
    //
    // - The model was: count minutes with MET >= 3.0, multiply by k (k = 100). On one flat walk it landed
    //   within +3 % of a pedometer, which is exactly the #194 trap CLAUDE.md warns about.
    // - Validated against **857 days** of the wearer's own Oura Cloud export it was unbiased at the median
    //   (-1.3 % held-out) but explained almost nothing: R^2 of active-minutes against real steps was only
    //   ~0.15-0.25, p10 -30 % / p90 +186 %. Refitting k did not help (least-squares 68, median-ratio 121,
    //   both worse than 100) - the weakness was the MET->steps relationship itself, not the constant.
    // - **2026-08-07, the falsifier: a 23-minute open-water swim, timed by an independent watch, with a
    //   ground truth of ZERO steps.** MET held 4.3-7.9 throughout (so the ring did see the activity - this
    //   was not a silent no-op), and **20 of the 24 minutes cleared MET >= 3.0, producing 2,000 phantom
    //   steps.** No threshold rescues it: even at MET >= 5.0 the swim still mints 1,400. The model was
    //   measuring EXERTION, not gait.
    // - The `maxTrustedActiveMinutes = 180` guard did NOT save it. That day totalled only 72 active
    //   minutes, so the guard never fired and the figure was printed with 28 % of it phantom. A guard on
    //   the DAY total cannot catch a bounded non-gait SESSION inside an ordinary day.
    //
    // Everything below this line is honest: active minutes, MET-minutes, mean/max MET and the energy
    // fields are direct aggregations of the decoded MET stream and were never in question. What was wrong
    // was converting them into a unit the ring never sends. Full write-up:
    // `OURA_STEPS_GROUNDTRUTH_20260803.md` (ADDENDUM 2026-08-07).
    //
    // The MET decode formula itself is still third-party and Tier B (see `OuraActivityInfo`); these
    // aggregates are for eyeballing against WHOOP active-kcal / Apple Health active energy, not for
    // scoring.

    /// Aggregate raw MET samples into an estimate. `epochSeconds` is the assumed per-sample duration
    /// (the calibration knob); `bodyMassKg` enables the energy fields; a sample counts as "active" when
    /// its MET reaches `moderateThresholdMET`. An empty input yields an all-zero estimate (never nil —
    /// "no activity" is a real answer). Scalars are rounded to 2 dp so a value compares exactly against
    /// a fixture (0.1 is not exactly representable in binary floating point).
    public static func estimate(metSamples: [Double],
                                epochSeconds: Double,
                                bodyMassKg: Double? = nil,
                                moderateThresholdMET: Double = 3.0) -> OuraActivityEstimate {
        let epochMinutes = epochSeconds / 60.0
        let epochHours = epochSeconds / 3600.0
        let count = metSamples.count

        let sum = metSamples.reduce(0, +)
        let mean = count > 0 ? sum / Double(count) : 0
        let peak = metSamples.max() ?? 0

        let metMinutes = sum * epochMinutes
        let activeCount = metSamples.reduce(into: 0) { acc, m in if m >= moderateThresholdMET { acc += 1 } }
        let activeMinutes = Double(activeCount) * epochMinutes

        let activeKcal: Double?
        let totalKcal: Double?
        if let mass = bodyMassKg {
            // Active = above-resting (subtract the 1-MET basal floor, clamped at 0 so a sub-resting
            // sample never contributes negative energy); total = gross including basal.
            let aboveResting = metSamples.reduce(0) { $0 + max($1 - 1.0, 0) }
            activeKcal = aboveResting * mass * epochHours
            totalKcal = sum * mass * epochHours
        } else {
            activeKcal = nil
            totalKcal = nil
        }

        func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
        return OuraActivityEstimate(
            sampleCount: count,
            epochSeconds: epochSeconds,
            meanMET: r2(mean),
            maxMET: r2(peak),
            metMinutes: r2(metMinutes),
            activeMinutes: r2(activeMinutes),
            estActiveKcal: activeKcal.map(r2),
            estTotalKcal: totalKcal.map(r2)
        )
    }

    /// Convenience over decoded 0x50 records: flattens every record's `met` series and aggregates.
    public static func estimate(from records: [OuraActivityInfo],
                                epochSeconds: Double,
                                bodyMassKg: Double? = nil,
                                moderateThresholdMET: Double = 3.0) -> OuraActivityEstimate {
        estimate(metSamples: records.flatMap { $0.met },
                 epochSeconds: epochSeconds,
                 bodyMassKg: bodyMassKg,
                 moderateThresholdMET: moderateThresholdMET)
    }
}
