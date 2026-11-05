import XCTest
@testable import ParakattApp

private final class SettingsQueryBridge: CoreBridge, @unchecked Sendable {
    override func listLlmModels(provider: String, baseUrl: String, apiKey: String?) throws -> [String] {
        XCTAssertFalse(Thread.isMainThread)
        return [provider, baseUrl, apiKey ?? ""]
    }
    override func getStatistics() throws -> [(String, String)] {
        XCTAssertFalse(Thread.isMainThread)
        return [("count", "7")]
    }
}

final class SettingsQueryTests: XCTestCase {
    @MainActor
    func testModelDiscoveryUsesTheSubmittedSettingsAndCompletesOnMain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try SettingsQueryBridge(modelsDir: directory.path, configDir: directory.path)
        let state = AppState(bridge: bridge)
        state.llmProvider = "ollama"
        state.llmBaseUrl = "http://submitted.invalid"
        state.llmApiKey = "fixture-key"
        let models: [String] = await withCheckedContinuation { continuation in
            state.fetchLlmModels {
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(returning: $0)
            }
            state.llmProvider = "lmstudio"
            state.llmBaseUrl = "http://changed.invalid"
            state.llmApiKey = "changed-key"
        }
        XCTAssertEqual(models, ["ollama", "http://submitted.invalid", "fixture-key"])
    }

    @MainActor
    func testStatisticsWorkRunsOffMainAndCompletesOnMain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try SettingsQueryBridge(modelsDir: directory.path, configDir: directory.path)
        let state = AppState(bridge: bridge)
        let stats: [(String, String)] = await withCheckedContinuation { continuation in
            state.queryStatistics {
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(stats.first?.0, "count")
        XCTAssertEqual(stats.first?.1, "7")
    }
}
