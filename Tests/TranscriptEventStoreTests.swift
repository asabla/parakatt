import XCTest
import ParakattCore
@testable import ParakattApp

final class TranscriptEventStoreTests: XCTestCase {
    private func event(_ chunk: UInt32, _ revision: UInt32, _ text: String, session: String = "recording") -> TranscriptionEvent {
        TranscriptionEvent(sessionId: session, chunkId: chunk, source: .mixed, revision: revision,
                           state: revision == 0 ? .recognized : .processed, text: text, error: nil)
    }
    func testReversedCompletionsReplaceTheirOwnChunks() {
        var store = TranscriptEventStore(sessionID: "recording")
        XCTAssertTrue(store.apply([event(0, 0, "first raw"), event(1, 0, "second raw")]))
        XCTAssertTrue(store.apply([event(1, 2, "Second."), event(0, 2, "First.")]))
        XCTAssertEqual(store.text, "First.\n\nSecond.")
        XCTAssertFalse(store.apply([event(0, 0, "stale"), event(0, 3, "previous session", session: "previous")]))
        XCTAssertEqual(store.text, "First.\n\nSecond.")
    }
    func testClosedSessionRejectsLateCallbacks() {
        var store = TranscriptEventStore(sessionID: "recording")
        _ = store.apply([event(0, 0, "recognized")])
        store.close()
        XCTAssertFalse(store.apply([event(0, 2, "late processing")]))
        XCTAssertEqual(store.text, "recognized")
    }
    func testFinishedEventRejectsLaterEventsInTheSameBatch() {
        var store = TranscriptEventStore(sessionID: "recording")
        let finished = TranscriptionEvent(sessionId: "recording", chunkId: 0, source: .mixed, revision: 0, state: .finished, text: "final", error: nil)
        _ = store.apply([event(0, 0, "recognized"), finished, event(0, 2, "late")])
        XCTAssertEqual(store.text, "recognized")
        XCTAssertFalse(store.apply([event(0, 3, "later")]))
    }
    func testQueueMaintainsSamplesAcrossCompactionAndPartialTail() {
        var queue = FloatQueue()
        queue.append(contentsOf: (0..<40_000).map(Float.init))
        XCTAssertEqual(queue.take(25_000), (0..<25_000).map(Float.init))
        queue.append(contentsOf: [40_000, 40_001])
        XCTAssertEqual(queue.count, 15_002)
        XCTAssertEqual(queue.take(20_000), (25_000...40_001).map(Float.init))
        XCTAssertTrue(queue.isEmpty)
    }
}
