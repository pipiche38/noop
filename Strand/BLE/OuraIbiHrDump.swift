import Foundation
import WhoopStore

/// Append-only JSONL sidecar for the Oura banked-IBI → HR history — a Tier-B RESEARCH corpus, never a
/// datastore row (see `OuraIbiHrDumpLine` for the honest-data rationale). Sibling of `OuraActivityDump`.
///
/// Captures the per-beat IBIs the HISTORY drain carries (green-IBI 0x80 etc., already quality-gated by the
/// decoders) at their REAL anchored time, so we can measure OFFLINE how dense/plausible an HR history
/// (HR = 60000/ibiMs) reconstructed from them is — during activity (where optical IBIs get noisy) vs sleep
/// (where the ring is still and beats are cleanest). Purely diagnostic; nothing reads it back; safe to delete.
///
/// Location: `<Application Support>/OpenWhoop/Diagnostics/oura-ibihr-<deviceId>.jsonl` — beside the SQLite.
final class OuraIbiHrDump {
    private let deviceId: String
    private let log: (String) -> Void
    private let highWaterKey: String
    /// Only records with `ringTs` STRICTLY above this are written; re-served (older) records are dropped.
    /// Persisted in UserDefaults so the dedup survives relaunches (a fresh drain re-emits old records).
    private var highWater: UInt32
    private var fileURL: URL?
    private var resolveFailed = false
    private var announced = false
    /// Last written record's `utc`, for the coverage-gap diagnostic. In-memory only (per launch) so a
    /// relaunch's first record never reports the expected hole since the app was last open.
    private var lastUtc: Int?

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init(deviceId: String, log: @escaping (String) -> Void) {
        self.deviceId = deviceId
        self.log = log
        self.highWaterKey = "oura.ibiHrDump.highwater.\(deviceId)"
        let stored = UserDefaults.standard.integer(forKey: highWaterKey)   // 0 when unset → writes everything
        self.highWater = stored > 0 ? UInt32(truncatingIfNeeded: stored) : 0
    }

    /// Append one anchored history-IBI record (all beats of one decode share `ringTs`). No-op when `ringTs`
    /// is not above the high-water (a re-serve) or when there are no beats. Best-effort: any file error is
    /// logged once and never disrupts the BLE path. Call ONLY with an anchored `utc` (the real beat time).
    func record(ringTs: UInt32, utc: Int, ibiMs: [Int]) {
        guard !ibiMs.isEmpty, ringTs > highWater else { return }
        guard let url = resolveURL() else { return }

        let line = OuraIbiHrDumpLine.encode(
            deviceId: deviceId, ringTs: ringTs, utc: utc,
            iso: Self.iso.string(from: Date(timeIntervalSince1970: TimeInterval(utc))), ibiMs: ibiMs)

        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
        } catch {
            log("Oura: IBI-HR dump write failed - \(error.localizedDescription)")
            return
        }

        highWater = ringTs
        UserDefaults.standard.set(Int(ringTs), forKey: highWaterKey)
        if !announced {
            announced = true
            log("Oura: IBI-HR history dump → \(url.path) [Tier-B research corpus, JSONL; HR = 60000/ibiMs]")
        }

        // Coverage-gap diagnostic (same purpose as the MET dump): a gap in banked IBIs means no
        // reconstructable HR for those minutes. Surfacing it tells us whether IBI history is dense enough
        // during activity/sleep to be worth wiring into strain. Threshold > 2 min ignores the normal seam.
        if let prev = lastUtc, utc - prev > 120 {
            log("Oura: IBI-HR gap - \((utc - prev) / 60) min no beats [\(Self.iso.string(from: Date(timeIntervalSince1970: TimeInterval(prev)))) → \(Self.iso.string(from: Date(timeIntervalSince1970: TimeInterval(utc))))]")
        }
        lastUtc = utc
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
            let url = dir.appendingPathComponent("oura-ibihr-\(safeId).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileURL = url
            return url
        } catch {
            resolveFailed = true
            log("Oura: IBI-HR dump unavailable - \(error.localizedDescription)")
            return nil
        }
    }
}
