import XCTest
@testable import OuraProtocol

/// Wear / charge inference (investigation 2026-07-19): a night can carry a full hypnogram and skin-temp yet
/// no heart rate because the ring staged a motionless object on the charger. These tests pin the two
/// signals that ARE present in real captures — the ring's "chg. detected"/"chg. stopped" STATE strings and
/// IBI (pulse) presence — and the guard that rejects a charger-staged phantom sleep. Numbers mirror the real
/// last-night capture: sleep window fully inside a chg.detected(10012704)->stopped(10178497) interval with
/// zero IBIs, while the worn nights have a pulse in-window.
final class OuraWearTests: XCTestCase {

    private func state(_ rt: UInt32, _ text: String) -> OuraState {
        OuraState(ringTimestamp: rt, stateCode: 0, text: text)
    }

    // MARK: - STATE-string semantics

    func testChargerStartStopStringMatching() {
        XCTAssertTrue(OuraWear.isChargerStart(state(1, "chg. detected")))
        XCTAssertTrue(OuraWear.isChargerStop(state(1, "chg. stopped")))
        // not a charger line
        XCTAssertFalse(OuraWear.isChargerStart(state(1, "hr enable")))
        XCTAssertFalse(OuraWear.isChargerStop(state(1, "orientation")))
        XCTAssertFalse(OuraWear.isChargerStart(state(1, "fea off")))
        // a nil / empty text never matches
        XCTAssertFalse(OuraWear.isChargerStart(OuraState(ringTimestamp: 1, stateCode: 8, text: nil)))
    }

    // MARK: - Charger intervals

    func testChargerIntervalsPairDetectedWithStopped() {
        // Two real charge cycles from the capture, fed out of order to prove the sort.
        let states = [
            state(10178497, "chg. stopped"),
            state(10012704, "chg. detected"),
            state(9626773, "chg. stopped"),
            state(9605322, "chg. detected"),
        ]
        let intervals = OuraWear.chargerIntervals(from: states)
        XCTAssertEqual(intervals, [
            OuraChargerInterval(startRingTime: 9605322, endRingTime: 9626773),
            OuraChargerInterval(startRingTime: 10012704, endRingTime: 10178497),
        ])
    }

    func testTrailingDetectedBecomesOpenInterval() {
        // A "detected" with no following "stopped" stays open (still charging at capture end).
        let intervals = OuraWear.chargerIntervals(from: [state(100, "chg. detected")])
        XCTAssertEqual(intervals, [OuraChargerInterval(startRingTime: 100, endRingTime: nil)])
        XCTAssertTrue(intervals[0].contains(999_999))          // open interval covers everything after start
        XCTAssertFalse(intervals[0].contains(50))
    }

    func testDuplicateDetectedDoesNotReopen() {
        // The ring emitted "chg. detected" twice at 10012704/10012705; that must be ONE interval.
        let states = [state(10012704, "chg. detected"),
                      state(10012705, "chg. detected"),
                      state(10178497, "chg. stopped")]
        XCTAssertEqual(OuraWear.chargerIntervals(from: states),
                       [OuraChargerInterval(startRingTime: 10012704, endRingTime: 10178497)])
    }

    // MARK: - Sleep-window classification (the phantom guard)

    func testLastNightWindowInsideChargerIsRejected() {
        // The real symptom: the sleep window (burst-back-laid ~9.5 h) sits fully inside the charge interval
        // and has NO pulse -> onCharger (phantom), the guard that should stop it being stored as a night.
        let charger = [OuraChargerInterval(startRingTime: 10012704, endRingTime: 10178497)]
        let verdict = OuraWear.classifySleepWindow(startRingTime: 10073562, endRingTime: 10107882,
                                                   chargerIntervals: charger, pulseRingTimes: [])
        XCTAssertEqual(verdict, .onCharger)
    }

    func testWornNightWithPulseIsMeasured() {
        // A real worn night: no overlapping charge interval and a pulse inside the window -> measured.
        let charger = [OuraChargerInterval(startRingTime: 10012704, endRingTime: 10178497)]
        let verdict = OuraWear.classifySleepWindow(startRingTime: 9160000, endRingTime: 9169416,
                                                   chargerIntervals: charger,
                                                   pulseRingTimes: [9165000, 9168000])
        XCTAssertEqual(verdict, .measured)
    }

    func testNoChargerButNoPulseIsNoHeartRate() {
        // Off the charger yet no pulse in the window (off-body on a desk) -> unverified, not measured.
        let verdict = OuraWear.classifySleepWindow(startRingTime: 5000, endRingTime: 6000,
                                                   chargerIntervals: [], pulseRingTimes: [100, 9000])
        XCTAssertEqual(verdict, .noHeartRate)
    }

    func testChargerPrecedenceOverPulse() {
        // Even if a stray pulse time lands in the window, an overlapping charge interval wins (the ring
        // reported the charger; a pulse during charging is impossible, so treat it as untrustworthy).
        let charger = [OuraChargerInterval(startRingTime: 1000, endRingTime: 2000)]
        let verdict = OuraWear.classifySleepWindow(startRingTime: 1200, endRingTime: 1800,
                                                   chargerIntervals: charger, pulseRingTimes: [1500])
        XCTAssertEqual(verdict, .onCharger)
    }

    // MARK: - Live tracker

    func testLiveTrackerPulseMeansWorn() {
        let t = OuraWearTracker()
        XCTAssertEqual(t.current, .unknown)
        t.note(state: state(1, "chg. detected"))
        XCTAssertEqual(t.current, .charging)
        t.note(state: state(2, "chg. stopped"))
        XCTAssertEqual(t.current, .off)
        t.notePulse()                                  // a beat can only come from a finger
        XCTAssertEqual(t.current, .worn)
        t.note(state: state(3, "chg. detected"))       // back on the charger
        XCTAssertEqual(t.current, .charging)
        t.reset()
        XCTAssertEqual(t.current, .unknown)
    }

    func testLivePulseTimeoutDowngradesWornToOff() {
        // The ring emits no "removed" event; a silent live-HR stream is the only signal. A timeout
        // downgrades worn -> off, but must NOT override charging or fabricate a not-worn from unknown.
        let t = OuraWearTracker()
        t.noteLivePulseTimeout()
        XCTAssertEqual(t.current, .unknown)            // no evidence yet -> unchanged
        t.notePulse()
        XCTAssertEqual(t.current, .worn)
        t.noteLivePulseTimeout()                       // stream went quiet -> removed
        XCTAssertEqual(t.current, .off)
        // charging is authoritative: a timeout never flips it to off.
        t.note(state: state(9, "chg. detected"))
        XCTAssertEqual(t.current, .charging)
        t.noteLivePulseTimeout()
        XCTAssertEqual(t.current, .charging)
    }
}
