import ParakattCore
import XCTest
@testable import ParakattApp

final class LlmSettingsTests: XCTestCase {
    func testSharedProcessingNamesAndProviderCapabilities() {
        XCTAssertEqual(TextProcessingPresentation.basicModes, ["dictation", "punctuation", "clean"])
        XCTAssertEqual(TextProcessingPresentation.title("dictation"), "Off")
        XCTAssertEqual(TextProcessingPresentation.title("punctuation"), "Punctuation")
        XCTAssertEqual(TextProcessingPresentation.title("clean"), "Grammar + punctuation")
        XCTAssertEqual(TextProcessingPresentation.title("email"), "Email")
        XCTAssertEqual(TextProcessingPresentation.title("custom"), "Custom")
        XCTAssertEqual(TextProcessingPresentation.selectionTitle("off"), "Custom: Off")
        XCTAssertTrue(TextProcessingPresentation.isReservedName(" Punctuation "))
        XCTAssertFalse(TextProcessingPresentation.isReservedName("Summary"))
        XCTAssertEqual(LlmProviderPresentation.options.map(\.id), ["", "ollama", "lmstudio", "chatgpt", "openai", "anthropic"])
        XCTAssertTrue(LlmProviderPresentation.isLocal("ollama"))
        XCTAssertFalse(LlmProviderPresentation.isLocal("chatgpt"))
        XCTAssertTrue(LlmProviderPresentation.needsApiKey("openai"))
        XCTAssertFalse(LlmProviderPresentation.needsApiKey("chatgpt"))
        XCTAssertFalse(LlmProviderPresentation.supportsAdvanced("chatgpt"))
        XCTAssertFalse(LlmProviderPresentation.supportsAdvanced(""))
    }

    @MainActor
    func testSwitchingAndNoneKeepSavedSettingsButRequireExplicitApply() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.path, configDir: directory.path)
        let state = AppState(bridge: bridge)
        state.settings.readCredential = { _ in nil }
        state.settings.writeCredential = { _, _ in true }
        state.selectLlmProvider("ollama")
        state.llmModel = "saved-local-model"
        XCTAssertTrue(state.configureLlm()) // constructs the provider; no inference or model-list request
        XCTAssertEqual(state.appliedLlmProvider, "ollama")
        state.selectLlmProvider("lmstudio")
        XCTAssertTrue(state.appliedLlmProvider.isEmpty)
        XCTAssertTrue(bridge.getLlmSettings().provider.isEmpty)
        state.selectLlmProvider("")
        XCTAssertTrue(state.appliedLlmProvider.isEmpty)
        XCTAssertEqual(bridge.getProviderSettings("ollama").model, "saved-local-model")
        state.selectLlmProvider("ollama")
        XCTAssertEqual(state.llmModel, "saved-local-model")
        XCTAssertTrue(state.appliedLlmProvider.isEmpty)
        state.activeMode = "punctuation"
        XCTAssertEqual(bridge.getActiveMode(), "punctuation")
        state.activeMode = "dictation"
        XCTAssertEqual(bridge.getActiveMode(), "dictation")
    }

    @MainActor
    func testProviderKeysStaySeparateAndSurviveSelectingNone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.path, configDir: directory.path)
        let state = AppState(bridge: bridge)
        var saved: [String: String] = [:]
        state.settings.readCredential = { saved[$0] }
        state.settings.writeCredential = { saved[$1] = $0; return true }
        state.selectLlmProvider("openai")
        state.llmApiKey = "fixture-openai"
        state.selectLlmProvider("anthropic")
        XCTAssertTrue(state.llmApiKey.isEmpty)
        state.llmApiKey = "fixture-anthropic"
        state.selectLlmProvider("")
        state.selectLlmProvider("openai")
        XCTAssertEqual(state.llmApiKey, "fixture-openai")
        state.selectLlmProvider("anthropic")
        XCTAssertEqual(state.llmApiKey, "fixture-anthropic")
        XCTAssertEqual(saved.count, 2)
    }
}
