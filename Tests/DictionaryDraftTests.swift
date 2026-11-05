import XCTest
import ParakattCore
@testable import ParakattApp

final class DictionaryDraftTests: XCTestCase {
    func testAddingAndRemovingRetainsExistingRuleOrderAndMetadata() throws {
        let rules = [
            ReplacementRule(pattern: "pr", replacement: "pull request", contextType: "in_app", contextValue: "com.example.editor", enabled: false),
            ReplacementRule(pattern: "Parakatt", replacement: "Parakatt", contextType: "when_mode", contextValue: "clean", enabled: true),
            ReplacementRule(pattern: "re:[", replacement: "invalid", contextType: "always", contextValue: nil, enabled: true)
        ]
        var draft = DictionaryDraft(rules: rules)
        draft.append(pattern: "new", replacement: "New")
        draft.remove(try XCTUnwrap(draft.entries.last).id)
        XCTAssertEqual(draft.entries.map(\.rule), rules)
        draft.remove(try XCTUnwrap(draft.entries.first).id)
        XCTAssertEqual(draft.entries.map(\.rule), Array(rules.dropFirst()))
    }
}
