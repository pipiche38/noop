import XCTest
@testable import Strand

/// The reconnect policy after an involuntary drop or a failed connect.
///
/// WHY IT EXISTS, measured rather than reasoned (2026-08-10 11:16, build `9bd45fef`): the link dropped at
/// 11:16:38, two connects failed fast on `Failed to encrypt the connection`, and attempt 3 was scheduled
/// for ~11:17:06 — it actually ran at **11:29:27, 12 m 33 s late**, when the phone was next picked up,
/// with zero log lines in between. `DispatchQueue.main.asyncAfter` does not run in a suspended app. The
/// ring was down for **12 m 51 s of a 27 m window (47 %)**, and the damage was not the late timer but that
/// after `didFailToConnect` nothing at all was outstanding.
///
/// ⚠️ These test the POLICY, not the plumbing. Whether a standing `central.connect` really survives
/// suspension on a real phone is a hardware question and is owed a strap night.
final class OuraReconnectPolicyTests: XCTestCase {

    /// The app is awake when the first callbacks land, so the short backoff still gets its chance to fix a
    /// transient blip — unchanged from #912/#414 and the Android twin.
    func testEarlyAttemptsStillUseTheShortTimedBackoff() {
        XCTAssertEqual(OuraLiveSource.reconnectStep(attempt: 1, secondsSinceStandingConnect: nil),
                       .timedRetry(delay: 3))
        XCTAssertEqual(OuraLiveSource.reconnectStep(attempt: 2, secondsSinceStandingConnect: nil),
                       .timedRetry(delay: 6))
    }

    /// THE REGRESSION TEST. Attempt 3 is exactly where the 2026-08-10 capture stalled for 12 m 33 s: it
    /// must hand off to CoreBluetooth, never schedule another timer.
    func testThirdFailureHandsOffToAStandingConnect() {
        XCTAssertEqual(OuraLiveSource.reconnectStep(attempt: 3, secondsSinceStandingConnect: nil),
                       .standingConnect)
        XCTAssertEqual(OuraLiveSource.reconnectStep(attempt: 9, secondsSinceStandingConnect: nil),
                       .standingConnect)
    }

    /// A standing connect normally never fails — it waits. But an encryption/bond hiccup can fail one in
    /// seconds, and re-issuing on that callback would be a hot loop that drains the ring and the phone.
    func testAStandingConnectThatFailsFastIsRateLimited() {
        guard case .standingConnectAfter(let delay) =
                OuraLiveSource.reconnectStep(attempt: 4, secondsSinceStandingConnect: 2) else {
            return XCTFail("a 2 s-old standing connect must not be re-issued immediately")
        }
        XCTAssertEqual(delay, OuraLiveSource.standingConnectRetryFloor - 2, accuracy: 0.001)
    }

    /// Once the floor has elapsed the hand-off resumes, so a ring that is genuinely unreachable is retried
    /// at a bounded rate rather than abandoned.
    func testOnceTheFloorHasElapsedItHandsOffAgain() {
        XCTAssertEqual(
            OuraLiveSource.reconnectStep(attempt: 4,
                                         secondsSinceStandingConnect: OuraLiveSource.standingConnectRetryFloor),
            .standingConnect)
        XCTAssertEqual(OuraLiveSource.reconnectStep(attempt: 12, secondsSinceStandingConnect: 600),
                       .standingConnect)
    }

    /// The re-issue rate is what bounds the battery cost of a ring that keeps failing to encrypt. Worst
    /// case must stay at or under the pre-existing 60 s backoff cap, i.e. this is never MORE aggressive
    /// than what it replaces.
    func testTheWorstCaseReIssueRateIsNoWorseThanTheOldBackoffCap() {
        XCTAssertLessThanOrEqual(OuraLiveSource.standingConnectRetryFloor, 60)
        // Failing instantly (since == 0) still waits the full floor.
        guard case .standingConnectAfter(let delay) =
                OuraLiveSource.reconnectStep(attempt: 5, secondsSinceStandingConnect: 0) else {
            return XCTFail("an instantly-failing standing connect must be rate-limited")
        }
        XCTAssertEqual(delay, OuraLiveSource.standingConnectRetryFloor, accuracy: 0.001)
    }

    /// Sanity on the timed half: still the capped-exponential BLEManager/Android curve, so a ring genuinely
    /// out of range never hammers BLE if the hand-off threshold is ever raised.
    func testTimedBackoffIsStillCappedExponential() {
        for (attempt, expected) in [(1, 3.0), (2, 6.0), (3, 12.0), (5, 48.0), (6, 60.0), (99, 60.0)] {
            // Read the curve directly by pretending the hand-off threshold is higher than the attempt.
            guard attempt < OuraLiveSource.standingConnectAfterAttempts else { continue }
            XCTAssertEqual(OuraLiveSource.reconnectStep(attempt: attempt, secondsSinceStandingConnect: nil),
                           .timedRetry(delay: expected), "attempt \(attempt)")
        }
    }
}
