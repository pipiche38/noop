import Foundation
import WhoopStore

/// Append-only JSONL sidecar for the Oura 0x50 activity/MET stream — a Tier-B RESEARCH corpus, never a
/// datastore row (see `OuraActivityDumpLine` for the honest-data rationale). Owns the file handle, the
/// on-disk path, the once-per-launch "here is the file" log line, and a persistent ring-time high-water so
/// the records the ring re-serves across reconnects (observed heavily under connection churn) are written
/// exactly once instead of duplicating the corpus.
///
/// Location: `<Application Support>/OpenWhoop/Diagnostics/oura-activity-<deviceId>.jsonl` — beside the app's
/// SQLite so the user can find it. Purely diagnostic and safe to delete; nothing reads it back.
final class OuraActivityDump {
    private let deviceId: String
    private let log: (String) -> Void
    private let highWaterKey: String
    /// Only records with `ringTs` STRICTLY above this are written; re-served (older) records are dropped.
    /// Persisted in UserDefaults so the dedup survives app relaunches (a fresh drain re-emits old records).
    private var highWater: UInt32
    private var fileURL: URL?
    private var resolveFailed = false
    private var announced = false

    /// #676 follow-up: rotate the sidecar past this size (keeping one previous ".1"), so an always-on
    /// research corpus is bounded to ~2× this on disk instead of growing forever. Matches Kotlin `MAX_BYTES`.
    private static let maxBytes = 25 * 1024 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Local-day key for the running tally. Matches `OuraLiveSource.activityDayFormatter` so the tally and
    /// the per-session log bucket a sample into the SAME day.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f   // local time zone by default
    }()

    /// UserDefaults key for the persisted per-local-day ACTIVE-MINUTE tally, `[yyyy-MM-dd: minutes]`.
    private let dailyActiveKey: String
    /// How many days of tally to keep. Small: this exists to answer "today so far", and a week is plenty of
    /// context without letting the dictionary grow forever.
    private static let dailyTallyDaysKept = 7
    /// A MET sample at or above this counts as an "active" minute — the same threshold
    /// `OuraActivityEstimator` uses by default, so the persisted tally and the estimator agree.
    private static let moderateThresholdMET = 3.0

    init(deviceId: String, log: @escaping (String) -> Void) {
        self.deviceId = deviceId
        self.log = log
        self.highWaterKey = "oura.activityDump.highwater.\(deviceId)"
        self.dailyActiveKey = "oura.activityDaily.\(deviceId)"
        let stored = UserDefaults.standard.integer(forKey: highWaterKey)   // 0 when unset → writes everything
        self.highWater = stored > 0 ? UInt32(truncatingIfNeeded: stored) : 0
    }

    /// Active minutes accumulated for `day` (local `yyyy-MM-dd`) across ALL sessions, or 0 if none.
    ///
    /// WHY THIS LIVES HERE: the per-day MET buffer in `OuraLiveSource` is in-memory and cleared on every
    /// connect, and the history drain resumes from a cursor, so that buffer only ever holds the records
    /// THIS session happened to fetch. A "daily total" read off it is really "total since this session's
    /// cursor" — on 2026-08-02 that was 395 of the day's 892 samples, which made the logged step estimate
    /// look accurate (4,900 vs a measured 4,605) purely by coincidence of where the cursor sat. This
    /// writer is the right home for the real tally because it is already the single choke point that sees
    /// every 0x50 record exactly once (the `highWater` dedup) and already persists across launches.
    func activeMinutes(forDay day: String) -> Double {
        (UserDefaults.standard.dictionary(forKey: dailyActiveKey)?[day] as? Double) ?? 0
    }

    /// Today's local-day key, for callers that just want "today so far".
    static func todayKey(now: Date = Date()) -> String { dayFormatter.string(from: now) }

    /// Fold one record's MET series into the persisted per-day tally. Called ONLY from the deduped write
    /// path, so a re-served record can never double-count. `secPerSample` is the assumed epoch (the same
    /// calibration knob the estimator takes), so a cadence change flows through here too.
    private func accumulateDailyActive(utc: Int, secPerSample: Int, met: [Double]) {
        let active = met.reduce(into: 0) { acc, m in if m >= Self.moderateThresholdMET { acc += 1 } }
        guard active > 0 else { return }
        let day = Self.dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(utc)))
        var tally = (UserDefaults.standard.dictionary(forKey: dailyActiveKey) as? [String: Double]) ?? [:]
        tally[day, default: 0] += Double(active) * Double(secPerSample) / 60.0
        // Bound the dictionary: keep only the most recent days (keys sort lexicographically as dates do).
        if tally.count > Self.dailyTallyDaysKept {
            for old in tally.keys.sorted().dropLast(Self.dailyTallyDaysKept) { tally.removeValue(forKey: old) }
        }
        UserDefaults.standard.set(tally, forKey: dailyActiveKey)
    }

    /// Append one anchored activity record. No-op when `ringTs` is not above the high-water (a re-serve),
    /// so the corpus stays deduped. Best-effort: any file error is logged once and never disrupts the BLE
    /// path. Call ONLY with an anchored `utc` (an un-anchored record has no real time axis and re-arrives
    /// anchored on the next drain).
    func record(ringTs: UInt32, utc: Int, state: Int, secPerSample: Int, met: [Double]) {
        guard ringTs > highWater else { return }
        guard var url = resolveURL() else { return }
        // #676 follow-up: bound the corpus (rotate to a single ".1", dropping the prior one) so an
        // always-on research sidecar can't grow unbounded — the same rotation the WHOOP5 deep-buffer log
        // uses. Twin of Kotlin OuraActivityDump. Best-effort: a rotation error falls through to the append.
        // Read the size via FileManager (a fresh stat) rather than URL.resourceValues, whose cache on the
        // reused URL object can return a stale small size and skip rotation entirely.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size > Self.maxBytes {
            let old = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
            fileURL = nil
            guard let fresh = resolveURL() else { return }
            url = fresh
        }

        let line = OuraActivityDumpLine.encode(
            deviceId: deviceId, ringTs: ringTs, utc: utc,
            iso: Self.iso.string(from: Date(timeIntervalSince1970: TimeInterval(utc))),
            state: state, secPerSample: secPerSample, met: met)

        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
        } catch {
            log("Oura: activity MET dump write failed - \(error.localizedDescription)")
            return
        }

        highWater = ringTs
        UserDefaults.standard.set(Int(ringTs), forKey: highWaterKey)
        // Past the dedup guard, so each 0x50 record contributes to the day's tally exactly once even
        // across reconnects/relaunches (see `activeMinutes(forDay:)`).
        accumulateDailyActive(utc: utc, secPerSample: secPerSample, met: met)
        if !announced {
            announced = true
            log("Oura: activity MET dump → \(url.path) [Tier-B research corpus, JSONL, deduped by ring-time]")
        }
    }

    /// Resolve (and create on first use) the sidecar file + its parent directory. Cached; a failure is
    /// logged once and latched so we never spam the strap log on a read-only volume.
    private func resolveURL() -> URL? {
        if let fileURL { return fileURL }
        if resolveFailed { return nil }
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("OpenWhoop/Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeId = deviceId.replacingOccurrences(of: "/", with: "_")
            let url = dir.appendingPathComponent("oura-activity-\(safeId).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileURL = url
            return url
        } catch {
            resolveFailed = true
            log("Oura: activity MET dump unavailable - \(error.localizedDescription)")
            return nil
        }
    }
}
