import XCTest
@testable import ParakattApp

final class TextInsertionServiceTests: XCTestCase {
    func testInsertEmptyTextReturnsFalse() {
        let service = TextInsertionService()
        let result = service.insertText("")
        XCTAssertFalse(result)
    }

    func testClipboardSetAndRestore() {
        // Verify the clipboard is set during insertion
        let pasteboard = NSPasteboard.general
        let originalContent = pasteboard.string(forType: .string)

        let service = TextInsertionService()
        // This will attempt insertion — may or may not succeed depending on
        // accessibility permissions in test environment, but clipboard should be set
        _ = service.insertText("test clipboard content")

        // After insertion, the clipboard should contain our text (before restore timer)
        let clipboardContent = pasteboard.string(forType: .string)
        XCTAssertEqual(clipboardContent, "test clipboard content")

        // Restore original clipboard
        pasteboard.clearContents()
        if let original = originalContent {
            pasteboard.setString(original, forType: .string)
        }
    }
}
