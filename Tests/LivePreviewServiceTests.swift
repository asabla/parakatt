import XCTest
import ParakattCore
@testable import ParakattApp

private final class PreviewCoreStub: LivePreviewCore {
    var available = true
    var chunkSize: UInt32 = 4
    var feedGate: DispatchSemaphore?
    let entered = DispatchSemaphore(value: 0)
    var chunks: [[Float]] = []
    var cancelled: [String] = []
    func shouldUseStreamingPreview() -> Bool { available }
    func streamingNativeChunkSamples() -> UInt32 { chunkSize }
    func startStreamingSession(sessionId: String) throws {}
    func feedStreamingChunk(sessionId: String, audioSamples: [Float]) throws -> StreamingChunkResult {
        entered.signal()
        if let gate = feedGate { _ = gate.wait(timeout: .now() + 3) }
        chunks.append(audioSamples)
        return StreamingChunkResult(committedText: sessionId, tentativeText: "", newlyCommittedText: sessionId)
    }
    func finishStreamingSession(sessionId: String) throws -> String { sessionId }
    func cancelStreamingSession(sessionId: String) { cancelled.append(sessionId) }
}

final class LivePreviewServiceTests: XCTestCase {
    func testFinishDrainsAndPadsTheFinalPartialMetadataSizedChunk() throws {
        let core = PreviewCoreStub()
        let service = LivePreviewService(bridge: core)
        let id = try service.start()
        service.enqueue([1, 2, 3, 4, 5])
        let done = expectation(description: "finished")
        service.stop { text in XCTAssertEqual(text, id); done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(core.chunks, [[1, 2, 3, 4], [5, 0, 0, 0]])
    }
    func testCancelRejectsUpdatesFromPreviousGeneration() throws {
        let core = PreviewCoreStub()
        core.feedGate = DispatchSemaphore(value: 0)
        let service = LivePreviewService(bridge: core)
        let previous = try service.start()
        service.enqueue([1, 2, 3, 4])
        XCTAssertEqual(core.entered.wait(timeout: .now() + 3), .success)
        service.cancel()
        let current = try service.start()
        service.onUpdate = { text, _, _ in XCTAssertNotEqual(text, previous) }
        core.feedGate?.signal()
        let done = expectation(description: "current finished")
        service.stop { text in XCTAssertEqual(text, current); done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(core.cancelled.contains(previous))
    }
    func testOverflowDisablesPreviewAndReportsIt() throws {
        let core = PreviewCoreStub()
        let service = LivePreviewService(bridge: core)
        _ = try service.start()
        let failed = expectation(description: "preview disabled")
        service.onError = { message in XCTAssertTrue(message.contains("Final transcription")); failed.fulfill() }
        service.enqueue(Array(repeating: 0.1, count: 160_001))
        wait(for: [failed], timeout: 3)
        XCTAssertTrue(core.chunks.isEmpty)
    }
    func testDisabledAndUnloadedModelsDoNotStart() {
        let core = PreviewCoreStub()
        core.available = false
        XCTAssertThrowsError(try LivePreviewService(bridge: core).start())
        core.available = true
        core.chunkSize = 0
        XCTAssertThrowsError(try LivePreviewService(bridge: core).start())
    }
}
