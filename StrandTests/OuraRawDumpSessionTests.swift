import XCTest
@testable import Strand

/// The raw Oura sidecar is scoped to ONE capture session (option 1 of the 2026-08-09 sidecar decision).
/// These pin the property that matters: the live file is never rolled part-way through a session, which is
/// the failure that cost a night of raw evidence on 2026-08-09 (a 25 MB threshold fired at 07:06:58, mid
/// drain, and the strap-log bundle does not collect the `.1`).
final class OuraRawDumpSessionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oura-raw-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func live() -> URL { dir.appendingPathComponent("oura-raw-ring1.jsonl") }
    private func previous() -> URL { dir.appendingPathComponent("oura-raw-ring1.jsonl.1") }
    private func lines(_ url: URL) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init)
    }

    func testOneSessionKeepsEveryRecordInTheLiveFile() {
        let dump = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        for i in 0..<500 { dump.record(bytes: [0x5D, UInt8(i % 256), 0x01, 0x02]) }
        // The whole session is in ONE file, and nothing was rolled aside part-way through.
        XCTAssertEqual(lines(live()).count, 500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous().path))
    }

    func testANewSessionRollsThePreviousOneAsideAndStartsEmpty() {
        let first = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        for _ in 0..<10 { first.record(bytes: [0xAA]) }
        XCTAssertEqual(lines(live()).count, 10)

        // A new object is a new session (one is built per OuraLiveSource).
        let second = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        second.record(bytes: [0xBB])

        XCTAssertEqual(lines(live()).count, 1, "the live file is THIS session only")
        XCTAssertEqual(lines(previous()).count, 10, "the previous session is retained as .1")
        XCTAssertTrue(lines(live())[0].contains("bb"), "the live file holds the new session's bytes")
    }

    func testOnlyOnePreviousSessionIsRetained() {
        for tag in [UInt8(0x11), 0x22, 0x33] {
            let dump = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
            dump.record(bytes: [tag])
        }
        XCTAssertTrue(lines(live())[0].contains("33"))       // newest session
        XCTAssertTrue(lines(previous())[0].contains("22"))   // the one before it
        // The oldest is gone: exactly two generations exist, so the corpus stays bounded.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(files.filter { $0.hasPrefix("oura-raw-ring1.jsonl") }.count, 2)
    }

    func testAnEmptyLeftoverIsReusedRatherThanSpendingTheRetainedGeneration() {
        // Build the state a killed session leaves behind: `.1` holds a REAL session, and the live file was
        // created but never written to (0 bytes). Rolling that empty file would spend the single retained
        // generation on nothing and discard the real one.
        let sessionA = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        sessionA.record(bytes: [0xAA])
        let sessionB = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        sessionB.record(bytes: [0xBB])                       // rolls A aside
        XCTAssertTrue(lines(previous())[0].contains("aa"))
        FileManager.default.createFile(atPath: live().path, contents: Data())  // B left nothing behind

        let sessionC = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        sessionC.record(bytes: [0xCC])

        XCTAssertEqual(lines(live()).count, 1)
        XCTAssertTrue(lines(live())[0].contains("cc"))
        XCTAssertTrue(lines(previous())[0].contains("aa"),
                      "the real previous session survived an empty leftover")
    }

    func testASessionThatReceivesNothingTouchesNoFilesAtAll() {
        let sessionA = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        sessionA.record(bytes: [0xAA])
        // A source that comes up and never gets a record never resolves, so it cannot roll anything.
        let silent = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        silent.record(bytes: [])                             // empty input is a no-op
        XCTAssertEqual(lines(live()).count, 1)
        XCTAssertTrue(lines(live())[0].contains("aa"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous().path))
    }

    func testCeilingStopsAppendingAndNeverRollsMidSession() {
        let dump = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        // One record is far under the ceiling, so drive the counter with a payload sized to cross it.
        let big = [UInt8](repeating: 0xEE, count: 64 * 1024)
        for _ in 0..<(OuraRawDump.maxSessionBytes / (128 * 1024) + 8) { dump.record(bytes: big) }

        let size = (try? FileManager.default.attributesOfItem(atPath: live().path))?[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, OuraRawDump.maxSessionBytes, "the ceiling bounds the session")
        XCTAssertGreaterThan(size, 0)
        // The critical property: hitting the ceiling must NOT roll the file, or we recreate the 2026-08-09
        // bug at a different threshold.
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous().path))
    }
}
