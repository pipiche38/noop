import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// `SleepStager.detectSleepFromPhaseEvents`: sleep-session detection from a device's OWN reported
/// phase codes (no gravity), the alternate path for a device with no accelerometer stream (e.g. an
/// Oura ring). Pure inputs/outputs, no BLE, no OuraProtocol dependency (the function only knows about
/// plain (ts, phase) tuples).
final class SleepStagerPhaseEventsTests: XCTestCase {

    /// One instant every `stepS` seconds, all reporting `phase`, spanning `[start, start + count*stepS)`.
    private func run(start: Int, count: Int, phase: Int, stepS: Int = 60) -> [(ts: Int, phase: Int)] {
        (0..<count).map { (ts: start + $0 * stepS, phase: phase) }
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(SleepStager.detectSleepFromPhaseEvents([]), [])
    }

    func testContiguousAlternatingStagesProducesOneSessionWithCorrectStagesAndEfficiency() {
        // 40 min light, 40 min deep, 40 min rem, one instant per minute, no gaps -> one 120 min session,
        // fully asleep (no wake code anywhere) -> efficiency 1.0.
        let events = run(start: 0, count: 40, phase: 1)
            + run(start: 2400, count: 40, phase: 2)
            + run(start: 4800, count: 40, phase: 3)
        let sessions = SleepStager.detectSleepFromPhaseEvents(events)
        XCTAssertEqual(sessions.count, 1)
        guard let s = sessions.first else { return }
        XCTAssertEqual(s.start, 0)
        XCTAssertEqual(s.end, 7200)   // last instant (7140) + its block's median gap (60s)
        XCTAssertEqual(s.efficiency, 1.0)
        XCTAssertEqual(s.stages.map { $0.stage }, ["light", "deep", "rem"])
        XCTAssertEqual(s.stages[0].start, 0);    XCTAssertEqual(s.stages[0].end, 2400)
        XCTAssertEqual(s.stages[1].start, 2400); XCTAssertEqual(s.stages[1].end, 4800)
        XCTAssertEqual(s.stages[2].start, 4800); XCTAssertEqual(s.stages[2].end, 7200)
    }

    func testWakeCodeLowersEfficiency() {
        // 60 min asleep (light) then 10 min awake, all contiguous one-minute instants.
        let events = run(start: 0, count: 60, phase: 1) + run(start: 3600, count: 10, phase: 0)
        let sessions = SleepStager.detectSleepFromPhaseEvents(events)
        XCTAssertEqual(sessions.count, 1)
        guard let s = sessions.first else { return }
        XCTAssertEqual(s.stages.map { $0.stage }, ["light", "wake"])
        // asleep = 3600s of 4200s total (the last wake instant's own trailing 60s also counts as wake).
        XCTAssertEqual(s.efficiency, 3600.0 / 4200.0, accuracy: 0.0001)
    }

    func testGapLargerThanNightContinuationSplitsIntoTwoSessions() {
        let gapS = (SleepStager.nightContinuationGapMin * 60) + 100   // just past the merge threshold
        let blockA = run(start: 0, count: 71, phase: 1)                       // 70 min span
        let blockB = run(start: 4200 + gapS, count: 71, phase: 2)             // 70 min span
        let sessions = SleepStager.detectSleepFromPhaseEvents(blockA + blockB)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].stages.map { $0.stage }, ["light"])
        XCTAssertEqual(sessions[1].stages.map { $0.stage }, ["deep"])
    }

    func testGapWithinNightContinuationMergesIntoOneSession() {
        let gapS = (SleepStager.nightContinuationGapMin * 60) - 100   // just under the merge threshold
        let blockA = run(start: 0, count: 71, phase: 1)
        let blockB = run(start: 4200 + gapS, count: 71, phase: 2)
        let sessions = SleepStager.detectSleepFromPhaseEvents(blockA + blockB)
        XCTAssertEqual(sessions.count, 1)
    }

    func testBlockShorterThanMinSleepMinIsDropped() {
        // 30 min span, well under the 60 min floor.
        let events = run(start: 0, count: 31, phase: 1)
        XCTAssertEqual(SleepStager.detectSleepFromPhaseEvents(events), [])
    }

    func testSingleInstantBlockIsDropped() {
        // A lone instant has no gap to derive a span from at all.
        XCTAssertEqual(SleepStager.detectSleepFromPhaseEvents([(ts: 0, phase: 1)]), [])
    }

    func testMajorityVoteWhenMultipleCodesShareOneTimestamp() {
        // ts=0 gets 3 votes (2x light, 1x deep) -> light wins for that instant.
        var events: [(ts: Int, phase: Int)] = [(ts: 0, phase: 1), (ts: 0, phase: 1), (ts: 0, phase: 2)]
        events += run(start: 60, count: 70, phase: 1)   // enough follow-on instants to clear minSleepMin
        let sessions = SleepStager.detectSleepFromPhaseEvents(events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.stages.map { $0.stage }, ["light"])
    }

    func testRestingHRAndAvgHRVPopulateFromSuppliedStreams() {
        let events = run(start: 0, count: 70, phase: 1)
        let hr = (0..<4200).map { HRSample(ts: $0, bpm: 50) }
        let rr = (0..<4200).map { RRInterval(ts: $0, rrMs: 900) }
        let sessions = SleepStager.detectSleepFromPhaseEvents(events, hr: hr, rr: rr)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.restingHR, 50)
        XCTAssertNotNil(sessions.first?.avgHRV)
    }

    func testNoHRRRSuppliedLeavesRestingHRAndAvgHRVNil() {
        let events = run(start: 0, count: 70, phase: 1)
        let sessions = SleepStager.detectSleepFromPhaseEvents(events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNil(sessions.first?.restingHR)
        XCTAssertNil(sessions.first?.avgHRV)
    }
}
