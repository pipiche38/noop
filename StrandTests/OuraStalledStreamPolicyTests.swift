import XCTest
@testable import Strand

/// `OuraLiveSource.shouldToggleSubscription` — the stalled-notify-subscription policy.
///
/// The policy is a pure static function precisely so it can be tested: `OuraLiveSource` owns a
/// `CBCentralManager` and cannot be constructed in a unit test, so without this split the decision would
/// have zero coverage. These tests pin the decision only; that a toggle actually clears a stalled stream
/// on real hardware is a strap claim and is called out as owed in the PR body.
///
/// The thresholds come from the 2026-08-10 `…-260810-1556` capture: over 7,493 inter-arrival gaps inside
/// live sessions the p99.9 gap is 4 s and the largest healthy gap is 4 s, while every genuine stall was
/// 893-928 s. Nothing at all falls between, which is why a 60 s cut is safe.
final class OuraStalledStreamPolicyTests: XCTestCase {

    // MARK: - It fires on the shape of stall that was actually measured

    func testFiresAfterTheMeasuredStallWindow() {
        // The real thing: ~900 s of silence, connected, idle-streaming, never toggled this session.
        XCTAssertTrue(OuraLiveSource.shouldToggleSubscription(
            secondsSinceInbound: 900, secondsSinceToggle: nil, isDraining: false))
    }

    func testDoesNotFireOnAHealthyChannel() {
        // p99.9 of healthy gaps is 4 s; 4 and even 30 must be left alone.
        for quiet in [0.0, 1, 4, 30, 59.9] {
            XCTAssertFalse(OuraLiveSource.shouldToggleSubscription(
                secondsSinceInbound: quiet, secondsSinceToggle: nil, isDraining: false),
                "a \(quiet)s gap is normal traffic and must not trigger a toggle")
        }
    }

    func testFiresJustPastTheThreshold() {
        XCTAssertFalse(OuraLiveSource.shouldToggleSubscription(
            secondsSinceInbound: 60, secondsSinceToggle: nil, isDraining: false))
        XCTAssertTrue(OuraLiveSource.shouldToggleSubscription(
            secondsSinceInbound: 60.1, secondsSinceToggle: nil, isDraining: false))
    }

    // MARK: - It cannot loop, and cannot interrupt a working channel

    func testNeverTogglesDuringAHistoryDrain() {
        // A drain IS inbound traffic; interrupting it to "fix" the channel it is using would be absurd.
        XCTAssertFalse(OuraLiveSource.shouldToggleSubscription(
            secondsSinceInbound: 900, secondsSinceToggle: nil, isDraining: true))
    }

    func testNeverTogglesBeforeAnythingHasEverArrived() {
        // No inbound yet is the auth/handshake path's problem. The channel must have worked once before
        // we are entitled to call it stalled — otherwise a failing connect would toggle forever.
        XCTAssertFalse(OuraLiveSource.shouldToggleSubscription(
            secondsSinceInbound: nil, secondsSinceToggle: nil, isDraining: false))
    }

    func testRateLimitedSoASilentRingCannotMakeUsLoop() {
        // Still silent, but we toggled 10 s ago: hold off.
        XCTAssertFalse(OuraLiveSource.shouldToggleSubscription(
            secondsSinceInbound: 900, secondsSinceToggle: 10, isDraining: false))
        XCTAssertFalse(OuraLiveSource.shouldToggleSubscription(
            secondsSinceInbound: 900, secondsSinceToggle: 119, isDraining: false))
        // Past the floor, try once more.
        XCTAssertTrue(OuraLiveSource.shouldToggleSubscription(
            secondsSinceInbound: 900, secondsSinceToggle: 120, isDraining: false))
    }

    func testAnUnwornRingCostsAtMostOneTogglePerFloor() {
        // A ring off the finger legitimately sends nothing. Walk 10 minutes of 15 s re-engage ticks and
        // count the toggles: the rate limit must hold it to one per 120 s, not one per tick.
        var lastToggle: TimeInterval? = nil
        var quiet: TimeInterval = 61          // already stalled when the walk starts
        var toggles = 0
        for _ in 0..<40 {                     // 40 ticks x 15 s = 10 minutes
            if OuraLiveSource.shouldToggleSubscription(
                secondsSinceInbound: quiet, secondsSinceToggle: lastToggle, isDraining: false) {
                toggles += 1
                lastToggle = 0
            }
            quiet += 15
            if let l = lastToggle { lastToggle = l + 15 }
        }
        XCTAssertEqual(toggles, 5, "10 minutes at a 120 s floor is 5 toggles, not 40")
    }

    // MARK: - Regression: the exact 2026-08-10 sequence

    func testTheMeasuredStallSequenceTogglesOnceEarlyAndNotDuringTheDrain() {
        // Replay of the 13:47:54 -> 14:03:22 gap: the app re-engages every 15 s, nothing arrives, and the
        // 300 s history fetch eventually pulls the backlog. The toggle must fire long BEFORE the fetch —
        // that is the whole point of a 60 s cut against a 300 s interval.
        var quiet: TimeInterval = 0
        var lastToggle: TimeInterval? = nil
        var firstToggleAt: TimeInterval? = nil
        for tick in 0..<20 {                  // 20 x 15 s = 300 s, i.e. up to the next history fetch
            let t = TimeInterval(tick * 15)
            if OuraLiveSource.shouldToggleSubscription(
                secondsSinceInbound: quiet, secondsSinceToggle: lastToggle, isDraining: false) {
                if firstToggleAt == nil { firstToggleAt = t }
                lastToggle = 0
            }
            quiet += 15
            if let l = lastToggle { lastToggle = l + 15 }
        }
        XCTAssertEqual(firstToggleAt, 75, "should recover ~75 s in, not wait for the 300 s fetch")
    }
}
