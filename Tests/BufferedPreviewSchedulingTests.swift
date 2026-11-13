import Foundation
import Combine
import ParakattCore
import XCTest
@testable import ParakattApp

private final class PreviewBridge: CoreBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var updates = 0
    private var finishes = 0
    let release = DispatchSemaphore(value: 0)
    @Locked var block = false
    @Locked var failFirst = false
    @Locked var finishing = false
    @Locked var failFinish = false
    let releaseFinish = DispatchSemaphore(value: 0)

    var counts: (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (updates, finishes)
    }
    override func isModelLoaded() -> Bool { true }
    override func streamingPreviewEnabled() -> Bool { true }
    override func startSession(sessionId: String, source: String = "meeting", mode: String = "dictation") throws {}
    override func processChunk(sessionId: String, audioSamples: [Float], sampleRate: UInt32,
                               chunkIndex: UInt32, chunkOverlapSecs: Double = 0,
                               mode: String, context: AppContextInfo?) throws -> ChunkResult {
        ChunkResult(text: "Recognized words", chunkIndex: chunkIndex, segments: [], chunkOffsetSecs: 0, llmError: nil)
    }
    override func getSessionText(sessionId: String) throws -> String { "Recognized words" }
    override func finishSession(sessionId: String, mode: String, context: AppContextInfo?,
                                source: String? = nil) throws -> TranscriptionResult {
        finishing = true
        guard releaseFinish.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "FinishTimeout", code: 1)
        }
        if failFinish { throw NSError(domain: "FinishFailed", code: 1) }
        return TranscriptionResult(text: "Final words.", durationSecs: 1, providerName: "fixture", segments: [], llmError: nil)
    }
    override func bufferedPreviewStart(sessionId: String) throws {}
    override func bufferedPreviewFinish(sessionId: String) throws -> String {
        lock.lock(); finishes += 1; lock.unlock()
        return ""
    }
    override func bufferedPreviewUpdate(sessionId: String, audioSamples: [Float], sampleRate: UInt32) throws -> StreamingChunkResult {
        lock.lock(); updates += 1; let count = updates; lock.unlock()
        if failFirst && count == 1 { throw NSError(domain: "PreviewBusy", code: 1) }
        if block && release.wait(timeout: .now() + 5) != .success { throw NSError(domain: "PreviewTimeout", code: 1) }
        return StreamingChunkResult(committedText: "", tentativeText: "preview words", newlyCommittedText: "")
    }
}

final class BufferedPreviewSchedulingTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (AppState, PreviewBridge, URL, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ["PARAKATT_STOP_LATENCY", "PARAKATT_DATA_ROOT"].map { name in
            (name, ProcessInfo.processInfo.environment[name])
        }
        setenv("PARAKATT_STOP_LATENCY", root.appendingPathComponent("result.json").path, 1)
        setenv("PARAKATT_DATA_ROOT", root.path, 1)
        let bridge = try PreviewBridge(modelsDir: root.appendingPathComponent("models").path, configDir: root.path)
        let state = AppState(bridge: bridge)
        return (state, bridge, root, {
            for (name, value) in previous {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
            try? FileManager.default.removeItem(at: root)
        })
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(predicate())
    }

    @MainActor
    func testBusyPreviewCanRetryTheSameAudio() async throws {
        let (state, bridge, _, cleanup) = try fixture()
        defer { state.recording.isRecording = false; state.shutdown(); cleanup() }
        bridge.failFirst = true
        try state.prepareRecordingLatencyFixture(samples: Array(repeating: 0.3, count: 16000), preview: true, incremental: false)
        try await waitUntil { !state.latencyFixturePreviewInFlight }
        XCTAssertEqual(bridge.counts.0, 1)
        state.updateLiveTranscription()
        try await waitUntil { !state.latencyFixturePreviewInFlight }
        XCTAssertEqual(bridge.counts.0, 2)
        XCTAssertEqual(state.livePreviewTentative, "preview words")
    }

    @MainActor
    func testShortRecordingKeepsRecognizedTextDuringSlowCleanupThenShowsFinalText() async throws {
        let (state, bridge, _, cleanup) = try fixture()
        defer { bridge.releaseFinish.signal(); state.shutdown(); cleanup() }
        try state.prepareRecordingLatencyFixture(samples: Array(repeating: 0.3, count: 16000), preview: false, incremental: false)
        state.liveTranscription = "Preview words"
        state.livePreviewCommitted = "Stale preview"
        state.stopRecording()
        XCTAssertEqual(state.liveTranscription, "Preview words")
        try await waitUntil { bridge.finishing && state.liveTranscription == "Recognized words" }
        XCTAssertTrue(state.isProcessing)
        bridge.releaseFinish.signal()
        try await waitUntil { !state.isProcessing }
        XCTAssertEqual(state.liveTranscription, "Final words.")
        XCTAssertEqual(state.lastTranscription, "Final words.")
    }

    @MainActor
    func testIncrementalFinishRetainsTextOnSuccessAndFailure() async throws {
        for fail in [false, true] {
            let (state, bridge, _, cleanup) = try fixture()
            defer { bridge.releaseFinish.signal(); state.shutdown(); cleanup() }
            bridge.failFinish = fail
            try state.prepareRecordingLatencyFixture(samples: Array(repeating: 0.3, count: 16000), preview: false, incremental: true)
            state.liveTranscription = "Preview words"
            state.stopRecording()
            try await waitUntil { bridge.finishing }
            XCTAssertTrue(state.isProcessing)
            let retainedText = state.liveTranscription
            XCTAssertFalse(retainedText?.isEmpty ?? true)
            bridge.releaseFinish.signal()
            try await waitUntil { !state.isProcessing }
            XCTAssertEqual(state.liveTranscription, fail ? retainedText : "Final words.")
            XCTAssertEqual(state.errorMessage != nil, fail)
        }
    }

    @MainActor
    func testStopKeepsOverlayActiveDuringDrainAndPreservesPreviewOnFailure() async throws {
        let (state, _, _, cleanup) = try fixture()
        defer { state.shutdown(); cleanup() }
        try state.prepareRecordingLatencyFixture(samples: [], preview: false, incremental: false)
        state.liveTranscription = "Keep these preview words"
        var visibility: [Bool] = []
        let observation = state.recording.$isRecording.combineLatest(state.recording.$isProcessing)
            .sink { visibility.append($0 || $1) }
        defer { observation.cancel() }
        state.stopRecording()
        XCTAssertTrue(state.isProcessing)
        XCTAssertTrue(state.latencyFixtureDraining)
        XCTAssertFalse(visibility.contains(false), "Stop must not publish a hidden phase before finishing")
        XCTAssertEqual(state.liveTranscription, "Keep these preview words")
        try await waitUntil { !state.isProcessing }
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(state.liveTranscription, "Keep these preview words")
    }

    @MainActor
    func testStopEndsPreviewImmediatelyAndRejectsALateCompletion() async throws {
        let (state, bridge, _, cleanup) = try fixture()
        defer { bridge.release.signal(); state.recording.isRecording = false; state.shutdown(); cleanup() }
        bridge.block = true
        try state.prepareRecordingLatencyFixture(samples: Array(repeating: 0.3, count: 16000), preview: true, incremental: false)
        try await waitUntil { bridge.counts.0 == 1 }
        state.stopRecording()
        XCTAssertEqual(bridge.counts.1, 1)
        // A later recording must not accept the previous session's completion.
        state.recording.isRecording = true
        bridge.release.signal()
        try await waitUntil { !state.latencyFixturePreviewInFlight }
        XCTAssertTrue(state.livePreviewTentative.isEmpty)
        XCTAssertNil(state.liveTranscription)
    }
}
