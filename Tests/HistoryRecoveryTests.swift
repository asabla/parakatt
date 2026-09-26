import XCTest
import ParakattCore
@testable import ParakattApp

final class HistoryRecoveryTests: XCTestCase {
    func testFailureAndRecoverySettingsThroughBindings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path)
        XCTAssertFalse(bridge.getRecoveryAudio())
        try bridge.setRecoveryAudio(true)
        try bridge.startSession(sessionId: "failed", source: "push_to_talk", mode: "dictation")
        XCTAssertThrowsError(try bridge.processChunk(sessionId: "failed", audioSamples: [Float](repeating: 0.1, count: 16000), sampleRate: 16000, chunkIndex: 0, mode: "dictation", context: nil))
        XCTAssertThrowsError(try bridge.finishSession(sessionId: "failed", mode: "dictation", context: nil, source: "push_to_talk"))
        bridge.cancelSession(sessionId: "failed")
        let draft = try XCTUnwrap(bridge.recordingDrafts().first)
        XCTAssertEqual(draft.failedChunks, 1)
        XCTAssertTrue(draft.audioAvailable)
        XCTAssertEqual(try bridge.getTranscriptionProcessing(id: "failed").status, "incomplete")
        XCTAssertEqual(try bridge.historySections(id: "failed").first?.status, "speech_failed")
        try bridge.setRecoveryAudio(false)
        XCTAssertFalse(try XCTUnwrap(bridge.recordingDrafts().first).audioAvailable)
        try bridge.discardRecordingDraft(id: "failed")
        XCTAssertTrue(try bridge.recordingDrafts().isEmpty)
    }
}
