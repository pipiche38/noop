import Foundation
import WhoopStore
import StrandImport
import OuraProtocol

/// Maps decoded Oura Ring BLE events → WhoopStore tables.
///
/// Called by SourceCoordinator at the end of each successful drain.  The ring's internal clock
/// ticks in deciseconds; we calibrate to real UTC using the `syncedAt` Date (recorded when
/// `reqSyncTime` was written) as the anchor for the most-recent event's timestamp.
enum OuraBLEImporter {

    static let importerVersion = 1

    // MARK: - Main entry point

    /// Flush decoded events into the store.  Returns an `ImportSummary` describing what was written;
    /// the caller (`SourceCoordinator`) discards the result — it is available for Import test mode.
    @discardableResult
    static func flush(events: [OuraEvent],
                      syncedAt: Date,
                      into store: WhoopStore,
                      deviceId: String) async throws -> ImportSummary {
        guard !events.isEmpty else {
            return ImportSummary(sourceKind: .ouraBLE, recordCount: 0,
                                 earliest: nil, latest: nil, countsByCategory: [:])
        }

        // Calibrate ring epoch → real UTC.
        // We assume the newest event's decisecond timestamp corresponds to `syncedAt`.
        let maxDecisec = events.map(\.timestampDecisec).max()!
        let epochOffset = syncedAt.timeIntervalSince1970 - Double(maxDecisec) / 10.0

        func unixDate(_ decisec: UInt32) -> Date {
            Date(timeIntervalSince1970: epochOffset + Double(decisec) / 10.0)
        }

        // Group raw HR, SpO2, and temperature readings by calendar day.
        var dayHRs:     [String: [Int]]    = [:]
        var daySpO2s:   [String: [Double]] = [:]
        var dayTemps:   [String: [Double]] = [:]

        for ev in events {
            let date = unixDate(ev.timestampDecisec)
            let day  = dayString(date)
            switch ev.tag {
            case OuraEventTag.greenIBIQuality.rawValue:
                if let bpm = decodeHRFromGreenIBI(ev.body), (30...200).contains(bpm) {
                    dayHRs[day, default: []].append(bpm)
                }
            case OuraEventTag.ibiPPG.rawValue:
                if let bpm = decodeHRFromIBIPPG(ev.body), (30...200).contains(bpm) {
                    dayHRs[day, default: []].append(bpm)
                }
            case OuraEventTag.spo2.rawValue:
                if let pct = decodeSpO2(ev.body) {
                    daySpO2s[day, default: []].append(pct)
                }
            case OuraEventTag.spo2RPi.rawValue:
                if let pct = decodeSpO2FromRatio(ev.body) {
                    daySpO2s[day, default: []].append(pct)
                }
            case OuraEventTag.temperature.rawValue, OuraEventTag.temperature2.rawValue:
                if let c = decodeTemperatureCelsius(ev.body) {
                    dayTemps[day, default: []].append(c)
                }
            default:
                break
            }
        }

        let allDays = Set(dayHRs.keys).union(daySpO2s.keys).union(dayTemps.keys).sorted()

        // Compute per-day skin-temp deviation: batch mean as the baseline.
        // Deviation is nil if we have fewer than 3 days of temperature data.
        let dayMeanTemps: [String: Double] = dayTemps.mapValues { mean($0) }
        let tempDeviation: [String: Double?]
        if dayMeanTemps.count >= 3 {
            let baseline = mean(Array(dayMeanTemps.values))
            tempDeviation = dayMeanTemps.mapValues { $0 - baseline }
        } else {
            tempDeviation = dayMeanTemps.mapValues { _ in nil }
        }

        // Build DailyMetric rows.
        var metrics: [DailyMetric] = []
        for day in allDays {
            let rhr     = dayHRs[day]?.min()
            let spo2    = daySpO2s[day].map { mean($0) }
            let tempDev = tempDeviation[day] ?? nil

            guard rhr != nil || spo2 != nil || tempDev != nil else { continue }

            metrics.append(DailyMetric(
                day: day,
                totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                lightMin: nil, disturbances: nil,
                restingHr: rhr,
                avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil,
                spo2Pct: spo2,
                skinTempDevC: tempDev,
                respRateBpm: nil))
        }
        let metricsWritten = try await store.upsertDailyMetrics(metrics, deviceId: deviceId)

        // Build MetricPoint rows for the metric explorer.
        var points: [MetricPoint] = []
        func add(_ day: String, _ key: String, _ v: Double?) {
            if let v { points.append(MetricPoint(day: day, key: key, value: v)) }
        }
        for day in allDays {
            add(day, "rhr",          dayHRs[day]?.min().map(Double.init))
            add(day, "spo2",         daySpO2s[day].map { mean($0) })
            add(day, "skin_temp_c",  dayMeanTemps[day])
        }
        try await store.upsertMetricSeries(points, deviceId: deviceId)

        // Build ImportSummary for Import test mode.
        let dates     = allDays.compactMap { parseDay($0) }
        let earliest  = dates.min()
        let latest    = dates.max()
        var counts: [String: Int] = [:]
        if !dayHRs.isEmpty   { counts["hr"]   = dayHRs.values.reduce(0) { $0 + $1.count } }
        if !daySpO2s.isEmpty  { counts["spo2"] = daySpO2s.values.reduce(0) { $0 + $1.count } }
        if !dayTemps.isEmpty  { counts["temp"] = dayTemps.values.reduce(0) { $0 + $1.count } }
        let total = metricsWritten + points.count

        return ImportSummary(sourceKind: .ouraBLE, recordCount: total,
                             earliest: earliest, latest: latest,
                             countsByCategory: counts)
    }

    // MARK: - Helpers

    private static func mean(_ xs: [Double]) -> Double {
        xs.reduce(0, +) / Double(xs.count)
    }

    private static func dayString(_ date: Date) -> String {
        let cal = Calendar.current
        let c   = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private static func parseDay(_ s: String) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        return Calendar.current.date(from: c)
    }
}
