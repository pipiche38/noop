import Foundation
import WhoopStore

/// Append-only JSONL sidecar for the Oura `0x6A sleep_period_info` stream — the ring's own per-window mean
/// HR and its CANDIDATE breath rate (see `OuraRespDumpLine` for why this tag, of all the Tier-B ones, earns
/// a file of its own). Direct twin of `OuraMotionDump`: owns the file handle, the on-disk path, the
/// once-per-launch "here is the file" log line, and a persistent ring-time high-water so records the ring
/// re-serves across reconnects are written exactly once instead of duplicating the corpus.
///
/// Location: `<Application Support>/OpenWhoop/Diagnostics/oura-resp-<deviceId>.jsonl` — beside the app's
/// SQLite so the user can find it, and collected into the diagnostics bundle as `oura-resp.jsonl`.
/// Purely diagnostic and safe to delete; nothing reads it back, nothing scores it.
///
/// 📌 WHY IT EXISTS AT ALL, given the bytes already reach `oura-raw.jsonl`: they reach it only when that
/// file happens to still hold the night. The raw sidecar is ~6 MB a night, rotates, and is the first thing
/// the bundle's fair-share cap trims; the strap log (the other place `0x6A` appears) is lost whenever the
/// app restarts after wake, which has now cost three consecutive overnight captures. This file is a few
/// hundred lines — ~1 record / 5 min — so it survives both. That is its whole purpose: make the NOOP half
/// of the respiration ledger independent of log survival.
final class OuraRespDump {
    private let deviceId: String
    private let log: (String) -> Void
    private let highWaterKey: String
    /// Only records with `ringTs` STRICTLY above this are written; re-served (older) records are dropped.
    /// Persisted in UserDefaults so the dedup survives app relaunches (a fresh drain re-emits old records).
    private var highWater: UInt32
    private var fileURL: URL?
    private var resolveFailed = false
    private var announced = false

    /// Rotate past this size (keeping one previous ".1"). Deliberately far smaller than the 25 MB the raw /
    /// motion corpora use: at ~200 bytes a line and one line per 5 minutes this holds well over a year of
    /// nights, so the cap is a runaway guard, never something a real capture can reach.
    private static let maxBytes = 2 * 1024 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init(deviceId: String, log: @escaping (String) -> Void) {
        self.deviceId = deviceId
        self.log = log
        self.highWaterKey = "oura.respDump.highwater.\(deviceId)"
        let stored = UserDefaults.standard.integer(forKey: highWaterKey)   // 0 when unset → writes everything
        self.highWater = stored > 0 ? UInt32(truncatingIfNeeded: stored) : 0
    }

    /// Append one anchored `0x6A` record. No-op when `ringTs` is not above the high-water (a re-serve), so
    /// the corpus stays deduped. Best-effort: any file error is logged once and never disrupts the BLE path.
    /// Call ONLY with an anchored `utc` — an un-anchored record has no real time axis (and re-arrives
    /// anchored on the next drain), and a respiration series with fabricated times is worse than none.
    func record(ringTs: UInt32, utc: Int, hr: Double, hrTrend: Double, mzci: Double, dzci: Double,
                breath: Double, breathV: Double, motion: Int, state: Int, cv: Double) {
        guard ringTs > highWater else { return }
        guard var url = resolveURL() else { return }
        // Bound the corpus (rotate to a single ".1", dropping the prior one). Read the size via a fresh
        // FileManager stat rather than URL.resourceValues, whose cache on the reused URL can return a stale
        // small size — the same trap OuraMotionDump documents.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size > Self.maxBytes {
            let old = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
            fileURL = nil
            guard let fresh = resolveURL() else { return }
            url = fresh
        }

        let line = OuraRespDumpLine.encode(
            deviceId: deviceId, ringTs: ringTs, utc: utc,
            iso: Self.iso.string(from: Date(timeIntervalSince1970: TimeInterval(utc))),
            hr: hr, hrTrend: hrTrend, mzci: mzci, dzci: dzci,
            breath: breath, breathV: breathV, motion: motion, state: state, cv: cv)

        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
        } catch {
            log("Oura: resp dump write failed - \(error.localizedDescription)")
            return
        }

        highWater = ringTs
        UserDefaults.standard.set(Int(ringTs), forKey: highWaterKey)
        if !announced {
            announced = true
            log("Oura: sleep_period 0x6A dump → \(url.path) [Tier-B candidate corpus, JSONL, deduped by ring-time]")
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
            let url = dir.appendingPathComponent("oura-resp-\(safeId).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileURL = url
            return url
        } catch {
            resolveFailed = true
            log("Oura: resp dump unavailable - \(error.localizedDescription)")
            return nil
        }
    }
}
