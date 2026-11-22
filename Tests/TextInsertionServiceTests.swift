import XCTest
@testable import ParakattApp

final class TextInsertionServiceTests: XCTestCase {
    @MainActor
    func testInsertEmptyTextReturnsEmpty() {
        XCTAssertEqual(TextInsertionService().insertText(""), .empty)
    }

    @MainActor
    func testDeniedPostPermissionPreservesClipboardAndSkipsEventPreparation() {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        let service = TextInsertionService(
            clipboard: ClipboardTransaction(pasteboard: pasteboard),
            actions: .init(
                isAccessibilityTrusted: { false },
                replaceSelection: { _ in
                    XCTFail("Accessibility was denied")
                    return false
                },
                canPostEvents: { false },
                makePasteRequest: {
                    XCTFail("Event posting was denied")
                    return nil
                }
            )
        )

        XCTAssertEqual(service.insertText("private transcription"), .permissionRequired)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testPasteRequestUsesTemporaryClipboardAfterAccessibilityReplacementFails() {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        let clipboard = ClipboardTransaction(pasteboard: pasteboard)
        var posted = false
        let service = TextInsertionService(
            clipboard: clipboard,
            actions: .init(
                isAccessibilityTrusted: { true },
                replaceSelection: { _ in false },
                canPostEvents: { true },
                makePasteRequest: {
                    {
                        XCTAssertEqual(pasteboard.string(forType: .string), "transcription")
                        posted = true
                    }
                }
            )
        )

        XCTAssertEqual(service.insertText("transcription"), .pasteRequested)
        XCTAssertTrue(posted)
        clipboard.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testClipboardRestoresAllFormatsAndItemsAcrossConsecutiveInsertions() throws {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        let richText = Data("rich text bytes".utf8)
        first.setData(richText, forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        pasteboard.writeObjects([first, second])
        let transaction = ClipboardTransaction(pasteboard: pasteboard)
        transaction.set("first transcription")
        transaction.set("second transcription")
        XCTAssertEqual(pasteboard.string(forType: .string), "second transcription")
        transaction.restore()
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.string(forType: .string), "original")
        XCTAssertEqual(items.first?.data(forType: .rtf), richText)
        XCTAssertEqual(items.last?.string(forType: .string), "second")
    }

    @MainActor
    func testClipboardRestorePreservesAUserCopy() {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        let transaction = ClipboardTransaction(pasteboard: pasteboard)
        transaction.set("transcription")
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }
}
