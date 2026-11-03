import Darwin
import Foundation
import ParakattCore
import XCTest
@testable import ParakattApp

private final class PreviewBridge: CoreBridge {
    private let lock = NSLock()
    private var updates = 0
    private var finishes = 0
    let release = DispatchSemaphore(value: 0)
    var block = false
    var failFirst = false

    var counts: (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (updates, finishes)
    }
    override func isModelLoaded() -> Bool { true }
    override func streamingPreviewEnabled() -> Bool { true }
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
