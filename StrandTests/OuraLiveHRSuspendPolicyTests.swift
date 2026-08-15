import XCTest
@testable import Strand

/// `OuraLiveSource.shouldSuspendLiveHR` — when the live-HR re-engage stands down because nobody is looking.
///
/// Like `shouldToggleSubscription`, the decision is a pure static precisely so it can be tested:
/// `OuraLiveSource` owns a `CBCentralManager` and cannot be constructed in a unit test. These tests pin the
/// decision only. That suspending the re-engage actually lets the ring run its own night suite is a STRAP
/// claim — it needs an overnight capture showing `check_sleep` reaching a run and `DHR_mode` leaving 3 —
/// and is called out as owed in the PR body, not asserted here.
///
/// Why the rule exists: across 10 nights the correlation between our overnight re-engage count and the ring
/// running its night suite is r = -0.91, but both of the nights that broke the pattern also broke the LINK
/// (one disconnect, one phone deliberately out of range), confounding "we stopped poking the ring" with "we
/// stopped talking to the ring at all". Suspending the re-engage while staying connected is what separates
/// them.
final class OuraLiveHRSuspendPolicyTests: XCTestCase {

    private let delay: TimeInterval = 900   // the 15-minute grace
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Presence

    func testNeverSuspendsWhileTheUserIsPresent() {
        // No screen-off timestamp means the user is here; no elapsed time can change that.
        XCTAssertFalse(OuraLiveSource.shouldSuspendLiveHR(
            screenOffAt: nil, now: t0.addingTimeInterval(86_400), delay: delay))
    }

    func testDoesNotSuspendDuringTheGrace() {
        // A glance-and-pocket must not cost the user their live HR for the evening.
        for elapsed in [0.0, 1, 60, 600, 899.9] {
            XCTAssertFalse(OuraLiveSource.shouldSuspendLiveHR(
                screenOffAt: t0, now: t0.addingTimeInterval(elapsed), delay: delay),
                "\(elapsed)s of screen-off is still inside the 15-minute grace")
        }
    }

    func testSuspendsAtTheThreshold() {
        XCTAssertTrue(OuraLiveSource.shouldSuspendLiveHR(
            screenOffAt: t0, now: t0.addingTimeInterval(delay), delay: delay))
        XCTAssertTrue(OuraLiveSource.shouldSuspendLiveHR(
            screenOffAt: t0, now: t0.addingTimeInterval(delay + 15), delay: delay))
    }

    func testStaysSuspendedAllNight() {
        // The predicate is elapsed-since-screen-off, not a one-shot edge, so a reconnect at 03:00 that
        // re-reaches `.streaming` still reads "suspended" and does not silently restart the stream.
        for hours in [1.0, 4, 8] {
            XCTAssertTrue(OuraLiveSource.shouldSuspendLiveHR(
                screenOffAt: t0, now: t0.addingTimeInterval(hours * 3600), delay: delay),
                "\(hours)h into a screen-off night the re-engage must still be suspended")
        }
    }

    // MARK: - The stall threshold that applies while suspended

    /// While live HR is suspended, silence is the ring behaving correctly rather than a stalled channel, so
    /// the recovery runs on `suspendedStallTimeout` (900 s) instead of the live-stream 60 s. Reusing 60 s
    /// would toggle the subscription on nearly every 300 s history-fetch tick and re-create overnight the
    /// exact ring-poking the suspend removes.
    func testSuspendedSilenceIsNotTreatedAsAStall() {
        for quiet in [61.0, 120, 300, 600, 899] {
            XCTAssertFalse(OuraLiveSource.shouldToggleSubscription(
                secondsSinceInbound: quiet, secondsSinceToggle: nil, isDraining: false, stallTimeout: 900),
                "\(quiet)s of quiet is expected with the stream suspended and must not toggle")
        }
    }

    func testSuspendedStallStillFiresOnceTwoFetchesHaveBroughtNothing() {
        // 900 s is two full 300 s fetch intervals plus margin, and sits inside the measured real-stall band
        // (893-928 s): nothing at all came back from two consecutive fetches, so the channel is dead.
        XCTAssertTrue(OuraLiveSource.shouldToggleSubscription(
            secondsSinceInbound: 901, secondsSinceToggle: nil, isDraining: false, stallTimeout: 900))
    }

    func testTheLiveThresholdIsUnchangedByDefault() {
        // The suspended timeout is opt-in per call site; the live path keeps its calibrated 60 s.
        XCTAssertTrue(OuraLiveSource.shouldToggleSubscription(
            secondsSinceInbound: 61, secondsSinceToggle: nil, isDraining: false))
    }
}
