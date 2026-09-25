import XCTest
import ParakattCore
@testable import ParakattApp

final class TranscriptExportTests: XCTestCase {
    func testProcessedTextDoesNotReplaceTimestampedRecognizedSpeech() throws {
        let segment = TimestampedSegment(text: "recognized words", startSecs: 1.25, endSecs: 2.75, speaker: "Me")
        let item = StoredTranscription(id: "test", createdAt: "2026-09-25T00:00:00Z", durationSecs: 3, source: "meeting", mode: "clean", audioSource: "mic", appContext: nil, title: nil, text: "Polished sentence.")
        let markdown = TranscriptExport.markdownBody(text: item.text, recognizedText: segment.text, segments: [segment])
        XCTAssertTrue(markdown.contains("## Processed text\n\nPolished sentence."))
        XCTAssertTrue(markdown.contains("[00:01] **Me:** recognized words"))
        XCTAssertFalse(markdown.contains("[00:01] Polished"))
        let object = TranscriptExport.jsonObject(item: item, recognizedText: segment.text, status: "completed", segments: [segment])
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["text"] as? String, item.text)
        XCTAssertEqual(decoded["recognized_text"] as? String, segment.text)
        let segments = try XCTUnwrap(decoded["segments"] as? [[String: Any]])
        XCTAssertEqual(segments[0]["start_secs"] as? Double, 1.25)
        XCTAssertEqual(segments[0]["text"] as? String, segment.text)
    }
}
