import Foundation
import WhoopStore

/// Append-only JSONL sidecar for the Oura SpO2 stream (`0x6F`/`0x7B`/`0x77`) — a research corpus for the
/// raw→% calibration investigation, NOT a datastore row (see `OuraSpO2DumpLine` for the rationale). Direct
/// twin of `OuraCvaPpgDump`/`OuraActivityDump`/`OuraMotionDump`: owns the file handle, the on-disk path,
/// the once-per-launch "here is the file" log line, and a persistent ring-time high-water so records the
/// ring re-serves across reconnects are written exactly once instead of duplicating the corpus.
///
/// GROUPING: unlike CVA-PPG/activity/real-steps (whose driver events already carry a whole record's
/// samples as one `[Int]` array), the driver flattens `.spo2` into ONE `OuraEvent` per sample — several
/// samples from the SAME record all share that record's single `ringTs` (`OuraDecoders.decodeSpO2PerSample`
/// / `decodeSpO2DC`). Deduping the naive per-sample way (`ringTs > highWater`) would keep only the FIRST
/// sample of every multi-sample record. So this writer re-groups consecutive same-`ringTs` samples into
/// ONE line itself (`record(...)` buffers; `flush()` commits the buffered group) before it ever reaches the
/// shared dedup-and-write path — the caller must call `flush()` at a natural batch boundary (a history
/// batch going quiet, or the drain finishing) so the LAST group of a batch is not left stranded in memory.
///
/// Location: `<Application Support>/OpenWhoop/Diagnostics/oura-spo2-<deviceId>.jsonl` — beside the app's
/// SQLite so the user can find it. Purely diagnostic and safe to delete; nothing reads it back.
final class OuraSpO2Dump {
    private let deviceId: String
    private let log: (String) -> Void
    private let highWaterKey: String
    /// Only records with `ringTs` STRICTLY above this are written; re-served (older) records are dropped.
    /// Persisted in UserDefaults so the dedup survives app relaunches (a fresh drain re-emits old records).
    private var highWater: UInt32
    private var fileURL: URL?
    private var resolveFailed = false
    private var announced = false

    /// The in-progress group: samples seen so far for the CURRENT `ringTs`, not yet written. A new `ringTs`
    /// flushes this first (see `record`); the caller flushes it explicitly at a batch boundary.
    private var pendingRingTs: UInt32?
    private var pendingUnit: String?
    private var pendingUtc: Int?
    private var pendingValues: [Int] = []

    /// Rotate the sidecar past this size (keeping one previous ".1"), so an always-on research corpus is
    /// bounded to ~2× this on disk instead of growing forever. Matches `OuraCvaPpgDump`/`OuraActivityDump`.
    private static let maxBytes = 25 * 1024 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init(deviceId: String, log: @escaping (String) -> Void) {
        self.deviceId = deviceId
        self.log = log
        self.highWaterKey = "oura.spo2Dump.highwater.\(deviceId)"
        let stored = UserDefaults.standard.integer(forKey: highWaterKey)   // 0 when unset → writes everything
        self.highWater = stored > 0 ? UInt32(truncatingIfNeeded: stored) : 0
    }

    /// Buffer one anchored SpO2 sample. Samples sharing the previous call's `ringTs` accumulate into the
    /// same pending group; a NEW `ringTs` flushes the previous group first. Call ONLY with an anchored
    /// `utc` (an un-anchored record has no real time axis and re-arrives anchored on the next drain).
    func record(ringTs: UInt32, utc: Int, value: Int, unit: String) {
        if let pending = pendingRingTs, pending != ringTs {
            flush()
        }
        pendingRingTs = ringTs
        pendingUtc = utc
        pendingUnit = unit
        pendingValues.append(value)
    }

    /// Commit the buffered group (if any) to disk. No-op when nothing is pending, or when the group's
    /// `ringTs` is not above the high-water (a re-serve), so the corpus stays deduped. Best-effort: any
    /// file error is logged once and never disrupts the BLE path. Call at a natural batch boundary (a
    /// history batch going quiet, or the drain finishing) so the last group of a batch is not stranded.
    func flush() {
        guard let ringTs = pendingRingTs, let utc = pendingUtc, let unit = pendingUnit else { return }
        let values = pendingValues
        pendingRingTs = nil
        pendingUtc = nil
        pendingUnit = nil
        pendingValues = []
        guard ringTs > highWater else { return }
        guard var url = resolveURL() else { return }
        // Bound the corpus (rotate to a single ".1", dropping the prior one) so an always-on research
        // sidecar can't grow unbounded — same rotation as OuraCvaPpgDump/OuraMotionDump/OuraActivityDump.
        // Read the size via a fresh FileManager stat rather than URL.resourceValues, whose cache on the
        // reused URL can return a stale small size.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size > Self.maxBytes {
            let old = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
            fileURL = nil
            guard let fresh = resolveURL() else { return }
            url = fresh
        }

        let line = OuraSpO2DumpLine.encode(
            deviceId: deviceId, ringTs: ringTs, utc: utc,
            iso: Self.iso.string(from: Date(timeIntervalSince1970: TimeInterval(utc))), unit: unit,
            values: values)

        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
        } catch {
            log("Oura: SpO2 dump write failed - \(error.localizedDescription)")
            return
        }

        highWater = ringTs
        UserDefaults.standard.set(Int(ringTs), forKey: highWaterKey)
        if !announced {
            announced = true
            log("Oura: SpO2 dump → \(url.path) [research corpus, JSONL, deduped by ring-time]")
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
            let url = dir.appendingPathComponent("oura-spo2-\(safeId).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileURL = url
            return url
        } catch {
            resolveFailed = true
            log("Oura: SpO2 dump unavailable - \(error.localizedDescription)")
            return nil
        }
    }
}
