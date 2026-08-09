import Foundation
import WhoopStore

/// Append-only JSONL sidecar for the Oura RAW capture — the UNDECODED history-drain notification bytes,
/// exactly as received. Complement to the *decoded* sidecars (`OuraActivityDump` = MET, `OuraIbiHrDump` =
/// HR from IBIs): those show what NOOP interpreted; this shows what the ring actually sent.
///
/// WHY: NOOP can drop packets, and the decoded files can only ever show what we decoded — so a hole in them
/// is ambiguous (ring never sent it, vs we dropped/failed to decode it). This raw capture removes the
/// ambiguity: after a full connect we know exactly which TLV records arrived. Reframe it OFFLINE (walk the
/// `2+len` records, read tag + ring-time) and a window empty in a decoded file but present here is a DECODE
/// drop; absent in both is RING-SIDE. It also preserves tags NOOP does not decode yet. Never scored; nothing
/// reads it back; safe to delete.
///
/// SCOPE: the HISTORY-drain record path only — the tap sits where reassembled TLV notifications are fed to
/// the driver, NOT the high-frequency live-HR push, so a night stays bounded. Auth/secure frames are
/// consumed before this tap, so only DATA records land here (no challenge/response crypto). Unlike the
/// decoded sidecars there is NO dedup high-water: a re-served record is still evidence the ring re-sent it,
/// and the offline reframer collapses duplicates by (tag, ring-time).
///
/// LIFETIME: the live file holds exactly ONE capture session. It is rolled to a single `.1` sibling when
/// this object resolves its file for the first time — i.e. at the START of a session — and never again
/// while the session runs. One `OuraRawDump` is built per `OuraLiveSource`, and a source survives BLE
/// reconnects (`SourceCoordinator` returns early when the active strap is unchanged), so a drain that
/// disconnects and re-engages several times still lands whole in one file.
///
/// WHY NOT a size threshold, which is what this used to do: a threshold can fire MID-DRAIN, and on
/// 2026-08-09 it did — 25 MB rolled at 07:06:58 during the morning offload, carrying 32,005 records of
/// that drain and 71 of the night's 75 `0x5D` records into the `.1`, which the strap-log bundle does not
/// collect. The night's raw evidence never left the device (it was recoverable only by pulling the file
/// off the phone by hand). Lowering the threshold makes that MORE frequent, not less; only rolling on a
/// session boundary removes it. The corpus stays bounded because a session is bounded: an overnight
/// drain is ~32,000 records ≈ 4 MB.
///
/// The multi-day corpus this used to accumulate is deliberately given up, because the bundle replaces it:
/// every capture now carries its own COMPLETE raw sidecar, and the bundles are what get archived. One
/// previous session is kept as `.1` purely so a session that ends without an export is not lost.
///
/// Location: `<Application Support>/OpenWhoop/Diagnostics/oura-raw-<deviceId>.jsonl` — beside the SQLite.
final class OuraRawDump {
    private let deviceId: String
    private let log: (String) -> Void
    private let directory: URL?
    private var fileURL: URL?
    private var resolveFailed = false
    private var announced = false
    private var sessionBytes = 0
    private var ceilingHit = false

    /// Hard ceiling on ONE session's file. Never a rotation — a session that somehow reaches this stops
    /// appending and says so once, because rolling mid-session is the exact failure this class was changed
    /// to remove. Far above a real overnight drain (~4 MB), so in practice it never fires; it exists so a
    /// pathological backlog cannot fill the disk.
    static let maxSessionBytes = 25 * 1024 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// `directory` is injectable so the session-roll behaviour is testable against a temp dir; production
    /// passes nil and gets `<Application Support>/OpenWhoop/Diagnostics`.
    init(deviceId: String, log: @escaping (String) -> Void, directory: URL? = nil) {
        self.deviceId = deviceId
        self.log = log
        self.directory = directory
    }

    /// Append one raw notification's bytes verbatim (hex-encoded), stamped with wall-clock arrival time.
    /// No-op on empty input. Best-effort: any file error is logged once and never disrupts the BLE path.
    func record(bytes: [UInt8]) {
        guard !bytes.isEmpty, let url = resolveURL() else { return }

        let now = Date()
        let line = OuraRawDumpLine.encode(
            deviceId: deviceId, utc: Int(now.timeIntervalSince1970),
            iso: Self.iso.string(from: now), bytes: bytes)

        guard let data = (line + "\n").data(using: .utf8) else { return }

        // Ceiling check against a running counter, not a stat per record: the file starts EMPTY each
        // session (resolveURL rolls it), so the counter is authoritative and costs no filesystem call.
        guard sessionBytes + data.count <= Self.maxSessionBytes else {
            if !ceilingHit {
                ceilingHit = true
                log("Oura: raw capture reached its \(Self.maxSessionBytes / (1024 * 1024)) MB session "
                    + "ceiling - no longer appending (the file is NOT rolled mid-session)")
            }
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
            sessionBytes += data.count
        } catch {
            log("Oura: raw dump write failed - \(error.localizedDescription)")
            return
        }

        if !announced {
            announced = true
            log("Oura: raw notification capture → \(url.path) [undecoded TLV bytes, JSONL; reframe offline]")
        }
    }

    /// Resolve the sidecar file + its parent directory, ROLLING the previous session's file aside on the
    /// first call so this session starts from empty. Cached, so the roll happens exactly once per object —
    /// which is what makes it a session boundary rather than a size threshold. A failure is logged once and
    /// latched so we never spam the strap log on a read-only volume.
    private func resolveURL() -> URL? {
        if let fileURL { return fileURL }
        if resolveFailed { return nil }
        do {
            let dir: URL
            if let directory {
                dir = directory
            } else {
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                dir = base.appendingPathComponent("OpenWhoop/Diagnostics", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeId = deviceId.replacingOccurrences(of: "/", with: "_")
            let url = dir.appendingPathComponent("oura-raw-\(safeId).jsonl")

            // Session roll: keep the previous session as ".1" (dropping the one before it) and begin fresh,
            // so the live file is always exactly this capture. An empty leftover is simply reused — rolling
            // it would spend the one retained generation on nothing.
            let existing = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            if existing > 0 {
                let previous = dir.appendingPathComponent(url.lastPathComponent + ".1")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: url, to: previous)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            sessionBytes = 0
            fileURL = url
            return url
        } catch {
            resolveFailed = true
            log("Oura: raw dump unavailable - \(error.localizedDescription)")
            return nil
        }
    }
}
