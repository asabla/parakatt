import XCTest
@testable import ParakattApp

final class CredentialMigrationTests: XCTestCase {
    func testFailedStorageRetainsSourceCredential() {
        var removed = false
        let migrated = CredentialMigration.migrate(value: "mock-key", account: "provider", read: { _ in nil }, write: { _, _ in false }) { removed = true }
        XCTAssertFalse(migrated)
        XCTAssertFalse(removed)
    }
    func testSuccessfulStoragePrecedesSourceRemoval() {
        var saved: [String: String] = [:]
        var removed = false
        let migrated = CredentialMigration.migrate(value: "mock-key", account: "anthropic", read: { saved[$0] }, write: { saved[$1] = $0; return true }) {
            XCTAssertEqual(saved["anthropic"], "mock-key")
            removed = true
        }
        XCTAssertTrue(migrated)
        XCTAssertTrue(removed)
    }
    func testDifferentStoredValueMustBeReplacedBeforeAcknowledgment() {
        var wrote = false
        XCTAssertTrue(CredentialMigration.migrate(value: "old-key", account: "openai", read: { _ in "current-key" }, write: { _, _ in wrote = true; return true }) {})
        XCTAssertTrue(wrote)
    }
}
