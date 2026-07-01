import XCTest
@testable import OuraProtocol

/// OuraClockAnchor: pure ring-time -> UTC conversion (OURA_PROTOCOL.md s5.5).
final class ClockAnchorTests: XCTestCase {
    func testForwardConversionAtDefaultTickRate() {
        // Anchor at ringTime 1000 == 2024-01-01T00:00:00Z (1704067200000 ms). 50 ticks later at
        // 100ms/tick == 5000ms later.
        let anchor = OuraClockAnchor(ringTime: 1000, utcMs: 1_704_067_200_000)
        XCTAssertEqual(anchor.utcMs(forRingTime: 1050), 1_704_067_205_000)
        XCTAssertEqual(anchor.utcSeconds(forRingTime: 1050), 1_704_067_205)
    }

    func testBackwardConversionForARingTimeBeforeTheAnchor() {
        // A historical record's ringTime can be BEFORE the anchor's (the anchor is set from
        // whatever time-sync arrives during the CURRENT connection; backfilled records are older).
        let anchor = OuraClockAnchor(ringTime: 1000, utcMs: 1_704_067_200_000)
        XCTAssertEqual(anchor.utcMs(forRingTime: 900), 1_704_067_190_000)
    }

    func testExactlyAtAnchorReturnsAnchorInstant() {
        let anchor = OuraClockAnchor(ringTime: 42, utcMs: 5_000)
        XCTAssertEqual(anchor.utcMs(forRingTime: 42), 5_000)
    }

    func testCustomTickRateIsHonoured() {
        let anchor = OuraClockAnchor(ringTime: 0, utcMs: 0, msPerTick: 1)
        XCTAssertEqual(anchor.utcMs(forRingTime: 500), 500)
    }

    /// A UInt32 ring-time far from the anchor (e.g. across a near-wraparound gap) must still convert
    /// via Int64 arithmetic without trapping or silently wrapping.
    func testLargeRingTimeDeltaDoesNotOverflow() {
        let anchor = OuraClockAnchor(ringTime: 10, utcMs: 0)
        let farFuture = UInt32.max - 10
        XCTAssertEqual(anchor.utcMs(forRingTime: farFuture), 100 * Int64(UInt32.max - 20))
    }
}
