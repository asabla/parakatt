import XCTest
@testable import ParakattApp

final class KeychainServiceTests: XCTestCase {
    private let testKey = "com.parakatt.test.key"

    override func tearDown() {
        KeychainService.delete(testKey)
        super.tearDown()
    }

    func testSetAndGet() {
        KeychainService.set("test-value-123", forKey: testKey)
        let result = KeychainService.get(testKey)
        XCTAssertEqual(result, "test-value-123")
    }

    func testGetMissing() {
        let result = KeychainService.get("nonexistent-key-12345")
        XCTAssertNil(result)
    }

    func testOverwrite() {
        KeychainService.set("first", forKey: testKey)
        KeychainService.set("second", forKey: testKey)
        XCTAssertEqual(KeychainService.get(testKey), "second")
    }

    func testDelete() {
        KeychainService.set("to-delete", forKey: testKey)
        KeychainService.delete(testKey)
        XCTAssertNil(KeychainService.get(testKey))
    }

    func testSetEmptyStringDeletes() {
        KeychainService.set("has-value", forKey: testKey)
        KeychainService.set("", forKey: testKey)
        XCTAssertNil(KeychainService.get(testKey))
    }
}
