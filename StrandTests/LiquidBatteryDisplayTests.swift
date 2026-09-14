import XCTest
import OuraProtocol
@testable import Strand

/// Pins the Liquid Today strap-battery ring's truth table (A3/B2,
/// docs/bugs/2026-07-15-strap-battery-backfill-observability.md).
///
/// The three inputs are independent live signals with independent sources, so the interesting cases are
/// the MIXED ones — charge % without a charging bit, a charging bit without a charge %, and a % that
/// outlived its link. Each of the three regressions below shipped, and each was visible on a wearer's
/// phone during a real strap incident. `resolve` is pure, so all of it pins with no strap and no BLE.
final class LiquidBatteryDisplayTests: XCTestCase {

    private typealias Display = LiquidTodayView.StrapBatteryDisplay

    /// The WHOOP-active shape every pre-#2208 case was written against: the ring arguments are absent.
    private func resolve(connected: Bool, batteryPct: Double?, charging: Bool?) -> Display {
        Display.resolve(activeIsWhoop: true, connected: connected, batteryPct: batteryPct, charging: charging,
                        ringPct: nil, ringWear: nil)
    }

    // MARK: - A3: "charging" must not be hostage to "charge %"

    /// THE regression. `charging` rides the strap's BATTERY_LEVEL event (~every 8 min); the % rides a
    /// different characteristic entirely. So the strap can tell us it is charging long before (or without
    /// ever) telling us a number. The old view nested the bolt inside `if let pct`, making this state
    /// unrenderable — it drew `bolt.slash` at a wearer who was sitting on the charger.
    func testChargingIsReportedEvenWithNoChargeReadingYet() {
        let d = resolve(connected: true, batteryPct: nil, charging: true)
        XCTAssertEqual(d, .pending(charging: true),
                       "a known charging state must survive a missing % — it is the wearer's live question")
    }

    /// The same state without the charging bit is "no reading yet", NOT "not charging" and NOT "dead".
    /// `.pending(charging: false)` and `.offline` must stay distinguishable so the view can render one as
    /// a pending ellipsis and the other as a crossed-out bolt.
    func testConnectedWithNoReadingIsPendingNotOffline() {
        let d = resolve(connected: true, batteryPct: nil, charging: nil)
        XCTAssertEqual(d, .pending(charging: false))
        XCTAssertNotEqual(d, .offline, "connected-but-silent is not the same claim as no link")
    }

    // MARK: - B2: a reading must not outlive its link

    /// `LiveState.batteryPct` is never cleared — `clearBiometrics()` deliberately leaves it set (that is
    /// what makes a nil % proof the 0x2A19 read never landed). So the LAST reading survives disconnect
    /// forever, and a view keying off `batteryPct` alone shows a dead strap's stale charge as if live.
    /// During the incident that rendered a 21 h old 11% identically to a fresh one.
    func testStaleChargeIsNotShownOnceTheLinkIsGone() {
        let d = resolve(connected: false, batteryPct: 11, charging: false)
        XCTAssertEqual(d, .offline, "a % with no link behind it must not render as a live reading")
    }

    /// Disconnect must also drop a charging bit — nothing about the old link is still true.
    func testStaleChargingFlagIsNotShownOnceTheLinkIsGone() {
        XCTAssertEqual(resolve(connected: false, batteryPct: nil, charging: true), .offline)
    }

    // MARK: - The normal path still reads normally

    func testConnectedReadingCarriesPctAndChargingThrough() {
        XCTAssertEqual(resolve(connected: true, batteryPct: 87.4, charging: true),
                       .charge(pct: 87.4, charging: true))
        XCTAssertEqual(resolve(connected: true, batteryPct: 87.4, charging: false),
                       .charge(pct: 87.4, charging: false))
    }

    /// `charging` is `Bool?` — nil means "the strap hasn't said" (no BATTERY_LEVEL event this session),
    /// which must read as not-charging, never as charging. Same `== true` posture as the rest of the app.
    func testUnknownChargingReadsAsNotCharging() {
        XCTAssertEqual(resolve(connected: true, batteryPct: 50, charging: nil),
                       .charge(pct: 50, charging: false))
    }

    // MARK: - #2208: the ring must not draw the strap's charge

    /// THE reported shape. `LiveState` is one object every source writes into: a streaming ring sets
    /// `connected`, and the WHOOP's `batteryPct` is never cleared, so the old three-signal gate passed on
    /// the strap's 72.4 under a ring that had itself reported 93 (the #2075 numbers, one screen over).
    func testRingActiveDrawsTheRingsChargeNotTheStraps() {
        let d = Display.resolve(activeIsWhoop: false, connected: true, batteryPct: 72.4, charging: true,
                                ringPct: 93, ringWear: .worn)
        XCTAssertEqual(d, .charge(pct: 93, charging: false),
                       "the ring's own charge, and the strap's charging bit must not ride along")
    }

    /// A ring that has not reported yet shows NOTHING, never the strap's number — an em dash is honest,
    /// the strap's charge under the ring's name is the bug.
    func testRingActiveWithNoRingReadingIsPendingNotTheStrapsCharge() {
        let d = Display.resolve(activeIsWhoop: false, connected: true, batteryPct: 72.4, charging: false,
                                ringPct: nil, ringWear: .worn)
        XCTAssertEqual(d, .pending(charging: false))
    }

    /// The ring's charging state is its wear state (the charger strings), not the strap's flag.
    func testRingChargingComesFromTheRingsWearState() {
        XCTAssertEqual(Display.resolve(activeIsWhoop: false, connected: true, batteryPct: nil, charging: nil,
                                       ringPct: 40, ringWear: .charging),
                       .charge(pct: 40, charging: true))
        XCTAssertEqual(Display.resolve(activeIsWhoop: false, connected: true, batteryPct: nil, charging: true,
                                       ringPct: nil, ringWear: .charging),
                       .pending(charging: true))
        XCTAssertEqual(Display.resolve(activeIsWhoop: false, connected: true, batteryPct: nil, charging: nil,
                                       ringPct: 40, ringWear: nil),
                       .charge(pct: 40, charging: false))
    }

    /// B2 holds for the ring too: no link, no reading.
    func testRingChargeIsNotShownOnceTheLinkIsGone() {
        XCTAssertEqual(Display.resolve(activeIsWhoop: false, connected: false, batteryPct: nil, charging: nil,
                                       ringPct: 93, ringWear: .worn), .offline)
    }

    /// And the WHOOP path ignores a stale ring charge left over from an earlier session.
    func testWhoopActiveIgnoresARingReading() {
        XCTAssertEqual(Display.resolve(activeIsWhoop: true, connected: true, batteryPct: 72.4, charging: false,
                                       ringPct: 93, ringWear: .worn),
                       .charge(pct: 72.4, charging: false))
    }
}
