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
    /// A WALKING-EQUIVALENT step estimate: `activeMinutes × stepsPerActiveMinute`. See that constant for
    /// the evidence and the (substantial) error bars. This is a DIAGNOSTIC figure for eyeballing a day's
    /// trend against a real pedometer — it is NOT a step count, must never mint a `steps` row, and must
    /// never be scored. NOOP's honest position stands: the ring exposes no step count NOOP can decode
    /// (`0x7E`/`0x7F` are model FEATURES, ground-truth-refuted 2026-08-01 — OURA_PROTOCOL.md §6.13).
    public let estStepsWalkingEquivalent: Double

    public init(sampleCount: Int, epochSeconds: Double, meanMET: Double, maxMET: Double,
                metMinutes: Double, activeMinutes: Double, estActiveKcal: Double?, estTotalKcal: Double?,
                estStepsWalkingEquivalent: Double = 0) {
        self.sampleCount = sampleCount
        self.epochSeconds = epochSeconds
        self.meanMET = meanMET
        self.maxMET = maxMET
        self.metMinutes = metMinutes
        self.activeMinutes = activeMinutes
        self.estActiveKcal = estActiveKcal
        self.estTotalKcal = estTotalKcal
        self.estStepsWalkingEquivalent = estStepsWalkingEquivalent
    }
}

/// Pure MET-stream aggregation. No database, no CoreBluetooth, no clock — the caller decides which
/// samples belong to the window/day (using the UTC anchor) and passes them in.
public enum OuraActivityEstimator {
    /// Steps assumed per ACTIVE minute (MET ≥ threshold) for `estStepsWalkingEquivalent`.
    ///
    /// WHY 100, AND WHY THIS IS A COARSE ESTIMATE, NOT A DECODE: the ring sends no step count NOOP can
    /// read — the `0x7E`/`0x7F` real_steps records were ground-truth-refuted on 2026-08-01 (no field is a
    /// count; they are the step model's INPUT features, OURA_PROTOCOL.md §6.13). So a step figure can only
    /// be INFERRED from an independent signal, and the MET stream is the one NOOP already decodes with a
    /// self-proven 60 s cadence.
    ///
    /// EVIDENCE (a single day, two overlapping measured references from one wearer):
    /// - Calibrating on a golf round (11,167 measured steps / 113 active minutes) gives **99 steps per
    ///   active minute** — which lands on ordinary walking cadence (~100–120 steps·min⁻¹) rather than on
    ///   an arbitrary fitted number, so 100 is used rather than the fitted 99.
    /// - HELD-OUT CHECK on a period the constant was NOT fitted to (the rest of that day, 2,182 measured
    ///   steps): predicts ~2,900, i.e. **≈ +30 %**. Coarse, but the right order — and far better than the
    ///   real_steps features, whose best equivalent model over-predicted the same held-out period by
    ///   **+218 % to +449 %**, which is what refuted them.
    ///
    /// KNOWN BIASES, all one-directional and unquantified: the MET stream has ring-side cadence gaps
    /// (~86 % minute coverage on a choppy day, §6.13) so active minutes UNDERCOUNT; MET underreads water
    /// activity (swims read near-rest); and an active minute that is not walking (cycling, rowing, a
    /// vigorous chore) contributes phantom steps. Treat this as "roughly how much walking was in the day",
    /// never as a pedometer.
    public static let stepsPerActiveMinute: Double = 100
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
            estTotalKcal: totalKcal.map(r2),
            estStepsWalkingEquivalent: (activeMinutes * stepsPerActiveMinute).rounded()
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
