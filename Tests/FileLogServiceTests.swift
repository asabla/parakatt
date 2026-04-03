import XCTest
@testable import ParakattApp

final class FileLogServiceTests: XCTestCase {
    func testLogCreatesFile() {
        let service = FileLogService.shared
        service.log("Test message from unit test", category: "Test")

        // Give the async queue a moment
        let expectation = XCTestExpectation(description: "Log file written")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Parakatt/logs")
            let logFile = logDir.appendingPathComponent("parakatt.log")

            XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path),
                          "Log file should exist at \(logFile.path)")

            if let content = try? String(contentsOf: logFile, encoding: .utf8) {
                XCTAssertTrue(content.contains("Test message from unit test"),
                              "Log file should contain test message")
            }

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}
