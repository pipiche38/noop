import Foundation

/// Ring-clock -> UTC anchor (OURA_PROTOCOL.md s5.5). The ring's own event stream carries only a
/// ring-clock `ringTimestamp` (ticks, NOT wall-clock); this anchors one ring-time to one UTC instant
/// so a transport can convert any OTHER ring-time (e.g. a backfilled historical record's own
/// `ringTimestamp`) into a real timestamp instead of stamping it at arrival wall-clock, which would be
/// wrong for anything that didn't just arrive live.
///
/// Pure value type - no CoreBluetooth, no wall-clock reads (the caller supplies both anchor readings).
/// The transport is responsible for keeping ONE current anchor: set it from a `0x42` time-sync event
/// (primary, per s5.5), or - only when no anchor exists yet - a `0x85` RTC beacon (secondary,
/// 1-second granularity, per s5.5 "gives 1-second-granularity unix_s as a secondary source").
public struct OuraClockAnchor: Equatable, Sendable {
    /// The ring-clock reading this anchor was taken at.
    public let ringTime: UInt32
    /// The UTC instant (epoch milliseconds) corresponding to `ringTime`.
    public let utcMs: Int64
    /// Ring-clock tick duration in milliseconds. Default 100 ms/tick (10 Hz), the documented default;
    /// burst mode (1 ms/tick, `factor_flag=1`) is not selectable from any decoded field today, so it is
    /// out of scope (matches the package's Tier-A-only discipline elsewhere).
    public let msPerTick: Int64

    public init(ringTime: UInt32, utcMs: Int64, msPerTick: Int64 = 100) {
        self.ringTime = ringTime
        self.utcMs = utcMs
        self.msPerTick = msPerTick
    }

    /// Convert another ring-clock reading to UTC epoch milliseconds: `utc_ms = anchor.utc_ms + factor *
    /// (target_rt - anchor.ring_time)`. Done in `Int64` throughout so a ring-time on the other side of a
    /// `UInt32` wraparound (or a regression before a reboot invalidates the anchor upstream) never
    /// silently wraps into a bogus small/large offset.
    public func utcMs(forRingTime target: UInt32) -> Int64 {
        utcMs + msPerTick * (Int64(target) - Int64(ringTime))
    }

    /// Convenience: UTC epoch SECONDS (the unit `Streams`/`ts` uses throughout the datastore).
    public func utcSeconds(forRingTime target: UInt32) -> Int {
        Int(utcMs(forRingTime: target) / 1000)
    }
}
