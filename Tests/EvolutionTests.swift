import XCTest
import SQLite3
import ParakattCore
@testable import ParakattApp

final class EvolutionTests: XCTestCase {
    @MainActor
    func testRecordingKeepsItsSelectedModeAndApplicationContext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path)
        let state = AppState(bridge: bridge)
        state.activeMode = "clean"
        try state.prepareRecordingContext(AppContextInfo(appBundleId: "test.other", selectedText: "Original selection"))
        XCTAssertEqual(state.recordingContext.mode, "clean")
        XCTAssertEqual(bridge.getActiveMode(), "clean")
        state.activeMode = "email"
        XCTAssertEqual(state.recordingContext.mode, "clean")
        XCTAssertEqual(state.recordingContext.application?.selectedText, "Original selection")
        try bridge.setAppModeDefault(bundleId: "test.editor", mode: "code")
        try state.prepareRecordingContext(AppContextInfo(appBundleId: "test.editor"))
        XCTAssertEqual(state.recordingContext.mode, "code")
        XCTAssertEqual(state.activeMode, "email")
        try state.prepareRecordingContext(nil)
        XCTAssertEqual(state.recordingContext.mode, "email")
        let reopened = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path)
        XCTAssertEqual(reopened.getActiveMode(), "email")
    }
    func testSpeechCapacityStaysBoundedAndCanBeReused() {
        let capacity = WorkCapacity(limit: 2)
        XCTAssertFalse(capacity.hasPendingWork)
        XCTAssertTrue(capacity.reserve()); XCTAssertTrue(capacity.reserve())
        XCTAssertTrue(capacity.hasPendingWork)
        XCTAssertFalse(capacity.reserve())
        capacity.release()
        XCTAssertTrue(capacity.hasPendingWork)
        XCTAssertTrue(capacity.reserve())
        XCTAssertFalse(capacity.reserve(3))
        capacity.release(2)
        XCTAssertFalse(capacity.hasPendingWork)
    }
    func testUnicodeSearchAndRepeatedMatches() {
        let text = "Åsa sa nej. ÅSA sa inte ja. 👋"
        let matches = TranscriptSearch.matches(in: [text, "Åsa"], query: "åsa")
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.map(\.section), [0, 0, 1])
        XCTAssertEqual((text as NSString).substring(with: matches[1].range), "ÅSA")
        XCTAssertEqual(TranscriptSearch.matches(in: [text], query: "👋").first?.range.length, 2)
        XCTAssertTrue(TranscriptSearch.matches(in: [text], query: "").isEmpty)
        XCTAssertEqual(TranscriptSearch.matches(in: [String(repeating: "a", count: 3000)], query: "a").count, 2000)
    }
    func testDetailCacheEvictsOldEntriesAndRejectsOversizeText() {
        var cache = HistoryDetailCache()
        for index in 0..<9 { cache.insert(HistoryDetailData(), for: "\(index)") }
        XCTAssertNil(cache.value(for: "0")); XCTAssertNotNil(cache.value(for: "8"))
        _ = cache.value(for: "1")
        cache.insert(HistoryDetailData(), for: "9")
        XCTAssertNotNil(cache.value(for: "1")); XCTAssertNil(cache.value(for: "2"))
        cache.insert(HistoryDetailData(processing: ProcessingSummary(recognizedText: String(repeating: "x", count: 500_001), status: "completed")), for: "large")
        XCTAssertNil(cache.value(for: "large"))
        cache.removeAll(); XCTAssertNil(cache.value(for: "8"))
    }
    func testCaptureJournalDrainsBeforeRecoveryIsOffered() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path)
        try bridge.setRecoveryAudio(true)
        let journal = try CaptureJournal(bridge: bridge, id: "before-model", source: "push_to_talk", mode: "dictation") { message in XCTFail(message) }
        journal.append(Array(repeating: 0.1, count: 1600), source: .mixed)
        XCTAssertTrue(try bridge.recordingDrafts().isEmpty)
        journal.finish()
        let drafts = try bridge.recordingDrafts()
        XCTAssertEqual(drafts.count, 1)
        XCTAssertTrue(try XCTUnwrap(drafts.first).audioAvailable)
        try bridge.setRecoveryAudio(false)
        XCTAssertFalse(try XCTUnwrap(bridge.recordingDrafts().first).audioAvailable)
    }
    @MainActor
    func testHistoryPaginationBeyondFiveHundredAndQueryErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("transcriptions.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for index in 0..<605 {
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO transcriptions(id,created_at,duration_secs,source,mode,text) VALUES('\(index)','2026-09-26',1,'meeting','dictation','searchable')", nil, nil, nil), SQLITE_OK)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        let state = AppState(bridge: bridge)
        var seen: Set<String> = []
        for offset in stride(from: 0, through: 600, by: 100) {
            let result: Result<[StoredTranscription], Error> = await withCheckedContinuation { continuation in
                state.queryHistoryPage(search: nil, source: nil, offset: UInt32(offset)) { continuation.resume(returning: $0) }
            }
            let rows = try result.get()
            for row in rows.prefix(100) { XCTAssertTrue(seen.insert(row.id).inserted) }
        }
        XCTAssertEqual(seen.count, 605)
        let invalid: Result<[StoredTranscription], Error> = await withCheckedContinuation { continuation in
            state.queryHistoryPage(search: "\"", source: nil, offset: 0) { continuation.resume(returning: $0) }
        }
        XCTAssertThrowsError(try invalid.get())
    }
}
