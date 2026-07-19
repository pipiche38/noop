import Foundation

// OuraWear: infer whether the ring is on a finger, on the charger, or idle — and flag sleep sessions the
// ring staged while it was NOT being worn.
//
// WHY THIS EXISTS (investigation 2026-07-19): a night can arrive with a full hypnogram and skin-temp yet
// ZERO heart rate. In the raw capture the ring's SleepNet still emits ~30 s phase codes for a motionless
// object on the charger, so NOOP would mint a "sleep session" for a night the wearer never had the ring
// on. The tell in the bytes: the whole ~9.5 h window sits inside the ring's own "chg. detected" ->
// "chg. stopped" STATE interval, and there is not a single IBI (a pulse can only come from a finger).
//
// WHY NOT 0x86: open_health documents an `aohr_event` (0x86) that "appears when worn", but that decoder is
// ported from libringeventparser.so and confirmed by code, not data — it has NEVER appeared in a capture
// (0 records here). So wear is inferred from two signals that ARE present and validated by real data:
//   - an IBI (pulse) record  -> the ring is on a finger (WORN);
//   - the ring's literal "chg. detected" / "chg. stopped" STATE strings -> an on-charger interval.
//
// Platform-pure, value types + one tiny live accumulator. No CoreBluetooth, no clock. Builds/tests on Linux.

/// The ring's wear / charge state for a live indicator.
public enum OuraWearState: String, Sendable, Codable, CaseIterable {
    case worn        // a pulse (IBI) was seen since the last charge/removal -> on a finger
    case charging    // between chg.detected and chg.stopped -> on the charger, not worn
    case off         // came off the charger but no pulse yet (idle / sitting on a desk)
    case unknown     // no evidence yet this session
}

/// A closed or still-open on-charger interval, in the ring's own ring-time. `endRingTime == nil` means the
/// charger was still connected at the end of the capture (a "chg. detected" with no following "stopped").
public struct OuraChargerInterval: Equatable, Sendable, Codable {
    public let startRingTime: UInt32
    public var endRingTime: UInt32?

    public init(startRingTime: UInt32, endRingTime: UInt32? = nil) {
        self.startRingTime = startRingTime
        self.endRingTime = endRingTime
    }

    /// Does `rt` fall within this interval? An open interval covers everything at/after its start.
    public func contains(_ rt: UInt32) -> Bool {
        rt >= startRingTime && (endRingTime.map { rt <= $0 } ?? true)
    }

    /// Does this interval overlap the ring-time window [a, b] (a <= b)? An open interval extends to the max.
    public func overlaps(_ a: UInt32, _ b: UInt32) -> Bool {
        let end = endRingTime ?? UInt32.max
        return a <= end && startRingTime <= b
    }
}

/// Why a sleep session's biometrics are (un)trustworthy, judged from the ring-time window it covers.
public enum OuraSleepSource: String, Sendable, Codable {
    case measured     // a pulse fell inside the window and it is not on the charger -> a real worn night
    case onCharger    // the window overlaps an on-charger interval -> phantom (the ring staged a still object)
    case noHeartRate  // not on the charger, but no pulse in the window -> unverified (off-body / on a desk)
}

public enum OuraWear {

    // MARK: - STATE-string semantics (clean-room: the ring's own words)

    /// True when a STATE (0x45/0x53) string reports the charger being CONNECTED (observed: "chg. detected").
    /// Matched on the decoded text, the honest signal — the ring literally says it — never a guessed code.
    public static func isChargerStart(_ s: OuraState) -> Bool {
        let t = (s.text ?? "").lowercased()
        return (t.contains("chg") || t.contains("charg")) && (t.contains("detect") || t.contains("start"))
    }

    /// True when a STATE string reports the charger being DISCONNECTED (observed: "chg. stopped").
    public static func isChargerStop(_ s: OuraState) -> Bool {
        let t = (s.text ?? "").lowercased()
        return (t.contains("chg") || t.contains("charg"))
            && (t.contains("stop") || t.contains("end") || t.contains("done") || t.contains("remov"))
    }

    // MARK: - Batch: charger intervals + sleep-window classification

    /// Fold STATE events (any arrival order) into on-charger intervals, sorted by ring-time. A "detected"
    /// opens an interval; the next "stopped" closes it. Repeated "detected"s while already open are ignored
    /// (the charger stayed connected); a trailing open "detected" becomes an open interval (nil end).
    public static func chargerIntervals(from states: [OuraState]) -> [OuraChargerInterval] {
        let sorted = states.sorted { $0.ringTimestamp < $1.ringTimestamp }
        var out: [OuraChargerInterval] = []
        var openStart: UInt32?
        for s in sorted {
            if isChargerStart(s) {
                if openStart == nil { openStart = s.ringTimestamp }
            } else if isChargerStop(s) {
                if let start = openStart {
                    out.append(OuraChargerInterval(startRingTime: start, endRingTime: s.ringTimestamp))
                    openStart = nil
                }
            }
        }
        if let start = openStart { out.append(OuraChargerInterval(startRingTime: start)) }
        return out
    }

    /// Classify a sleep window [startRingTime, endRingTime] against the charger intervals and the ring-times
    /// at which a pulse (IBI) was recorded. `onCharger` takes precedence (the ring reported the charger),
    /// then a window with no pulse is `noHeartRate`, else `measured`. This is the guard that rejects a
    /// hypnogram the ring staged for a motionless ring on the charger. Ring-time only — caller supplies the
    /// window and the pulse times in the same ring clock, so no wall-clock anchor is needed.
    public static func classifySleepWindow(startRingTime: UInt32, endRingTime: UInt32,
                                           chargerIntervals: [OuraChargerInterval],
                                           pulseRingTimes: [UInt32]) -> OuraSleepSource {
        let a = min(startRingTime, endRingTime)
        let b = max(startRingTime, endRingTime)
        if chargerIntervals.contains(where: { $0.overlaps(a, b) }) { return .onCharger }
        let hasPulse = pulseRingTimes.contains { $0 >= a && $0 <= b }
        return hasPulse ? .measured : .noHeartRate
    }
}

/// A tiny LIVE state machine for a wear/charge indicator. Feed it STATE events and pulses as they stream in
/// real time; read `current`. Live semantics only: a pulse always means WORN (a finger), a charge string
/// means CHARGING/OFF, latest wins. For a HISTORY re-serve (events out of order) use `OuraWear`'s batch
/// window classifier instead — feeding a re-served stream here would flap the indicator.
public final class OuraWearTracker {
    public private(set) var current: OuraWearState = .unknown

    public init() {}

    /// A decoded STATE (0x45/0x53) event.
    public func note(state: OuraState) {
        if OuraWear.isChargerStart(state) { current = .charging }
        else if OuraWear.isChargerStop(state) { current = .off }
    }

    /// A LIVE heart-rate beat was streamed (the 0x2F live-HR push) — that stream exists only while the ring
    /// is measuring on a finger, so the ring is WORN. Do NOT call this for a banked/history IBI: a history
    /// re-serve can carry beats from a PAST night and would falsely flip the badge to worn while the ring
    /// is actually on the charger. Live push only.
    public func notePulse() { current = .worn }

    /// No live beat has arrived for longer than expected while HR was streaming — the ring came off the
    /// finger (the ring emits no "removed" event; a stopped live-HR stream is the only signal). Downgrades
    /// `.worn` -> `.off` only; never overrides `.charging` (the charger STATE is authoritative) or a state
    /// that was already not-worn. The caller owns the timing (a wall-clock watchdog); the tracker stays pure.
    public func noteLivePulseTimeout() {
        if current == .worn { current = .off }
    }

    /// Reset to `.unknown` (a fresh connection / session).
    public func reset() { current = .unknown }
}
