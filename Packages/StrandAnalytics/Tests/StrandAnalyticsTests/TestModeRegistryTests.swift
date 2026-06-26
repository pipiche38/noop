import XCTest
@testable import StrandAnalytics

final class TestModeRegistryTests: XCTestCase {

    func testPhase1ShipsExactlySleepThenBattery() {
        XCTAssertEqual(TestModeRegistry.all.map(\.domain), [.sleep, .battery])
        XCTAssertEqual(TestModeRegistry.all.map(\.id), ["sleep", "battery"])
    }

    func testLookupByDomain() {
        XCTAssertEqual(TestModeRegistry.mode(.sleep)?.title, "Sleep & Rest")
        XCTAssertEqual(TestModeRegistry.mode(.battery)?.title, "Battery & Charging")
        XCTAssertNil(TestModeRegistry.mode(.steps))
    }

    func testSleepCaptureSet() {
        XCTAssertEqual(TestModeRegistry.mode(.sleep)?.captures, [
            "gateTrace", "gravityCoverage", "hrDensity", "wristOff", "perEpochFeatures",
            "hypnogramV1V2", "ppgOnlyNight", "skinTempDsp", "restSubScores",
        ])
    }

    func testSleepIsGuidedThreeNights() {
        guard case .guided(let unit, let count)? = TestModeRegistry.mode(.sleep)?.capture else {
            return XCTFail("sleep should be guided")
        }
        XCTAssertEqual(unit, .nights)
        XCTAssertEqual(count, 3)
    }

    func testBatteryIsGuidedThreeDays() {
        guard case .guided(let unit, let count)? = TestModeRegistry.mode(.battery)?.capture else {
            return XCTFail("battery should be guided")
        }
        XCTAssertEqual(unit, .days)
        XCTAssertEqual(count, 3)
    }

    func testBatteryCaptureSetAndReadout() {
        XCTAssertEqual(TestModeRegistry.mode(.battery)?.captures, [
            "socSeries", "chargeSteps", "offWristGaps", "dischargeRun", "fittedSlope",
            "sourceMeasuredVsRated", "batteryGates",
        ])
        XCTAssertEqual(TestModeRegistry.mode(.battery)?.liveReadout, ["currentSoc", "estimateDaysLeft", "slopeSource"])
    }

    func testSleepQuestionnaireKeys() {
        XCTAssertEqual(TestModeRegistry.mode(.sleep)?.questionnaire.map(\.id), [
            "sleepTimes", "awakeStill", "naps", "shiftWork", "chargeTiming", "healthSleep",
        ])
    }

    func testNeitherPhase1ModeRequires5MGOrScreenshot() {
        for m in TestModeRegistry.all {
            XCTAssertFalse(m.requires5MG)
            XCTAssertFalse(m.includesScreenshot)
        }
    }
}

// MARK: - Group E (Sleep & Rest): pin the questionnaire kinds + live-readout ids against drift.
// The ids are meta.json keys and the readout ids the panel binds; a later edit that renames or drops
// one must fail here. The id ORDER is already covered by TestModeRegistryTests.testSleepQuestionnaireKeys.

final class TestModeRegistrySleepTests: XCTestCase {
    func testSleepQuestionnaireIdsAndKinds() {
        let sleep = TestModeRegistry.mode(.sleep)!
        XCTAssertEqual(sleep.questionnaire.map(\.id),
                       ["sleepTimes", "awakeStill", "naps", "shiftWork", "chargeTiming", "healthSleep"])
        XCTAssertEqual(sleep.questionnaire.first { $0.id == "shiftWork" }?.kind, .yesNo)
        XCTAssertEqual(sleep.questionnaire.first { $0.id == "healthSleep" }?.kind, .yesNo)
        XCTAssertEqual(sleep.questionnaire.first { $0.id == "sleepTimes" }?.kind, .text)
        XCTAssertEqual(sleep.questionnaire.first { $0.id == "naps" }?.kind, .text)
        // No em-dash in any prompt (the writing-voice rule applies to user-facing strings too).
        XCTAssertFalse(sleep.questionnaire.contains { $0.prompt.contains("\u{2014}") })
    }

    func testSleepLiveReadoutIds() {
        let sleep = TestModeRegistry.mode(.sleep)!
        XCTAssertEqual(sleep.liveReadout, ["hrDensityNow", "gravityCoverageNow", "lastNightGateFired"])
    }
}
