import XCTest
import ParakattCore
@testable import ParakattApp

@MainActor
private final class SettingsFixture: AppState {
    override func loadLlmApiKeyFromKeychain() {}
    override func reloadSpeechModels() {}
}

final class SettingsContractTests: XCTestCase {
    @MainActor
    func testProfileRefreshesPrivacyControls() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path)
        try bridge.setRecoveryAudio(false)
        try bridge.setLlmContextEnabled(false)
        try bridge.saveProfile("off")
        let state = SettingsFixture(bridge: bridge)
        state.setRecoveryAudio(true)
        state.setLlmContextEnabled(true)
        XCTAssertTrue(state.settings.recoveryAudio)
        XCTAssertTrue(state.settings.llmContextEnabled)
        state.loadProfile("off")
        XCTAssertFalse(bridge.getRecoveryAudio())
        XCTAssertFalse(bridge.getLlmContextEnabled())
        XCTAssertFalse(state.settings.recoveryAudio)
        XCTAssertFalse(state.settings.llmContextEnabled)
    }
    @MainActor
    func testFailedBehaviorSavesKeepVisibleSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path)
        let state = SettingsFixture(bridge: bridge)
        try bridge.setAutoPaste(true)
        let file = directory.appendingPathComponent("config.toml")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        state.setAutoPaste(false)
        XCTAssertTrue(state.autoPaste)
        XCTAssertTrue(try bridge.getAutoPaste())
        state.setShowOverlay(false)
        XCTAssertTrue(state.showRecordingOverlay)
        state.setSpeakerLabelsEnabled(true)
        XCTAssertFalse(state.speakerLabelsEnabled)
        XCTAssertNotNil(state.errorMessage)
    }
    @MainActor
    func testProfileCannotReplaceAnActiveRecordingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path)
        try bridge.saveProfile("default")
        let state = SettingsFixture(bridge: bridge)
        state.setRecoveryAudio(true)
        state.isRecording = true
        state.loadProfile("default")
        XCTAssertTrue(bridge.getRecoveryAudio())
        XCTAssertTrue(state.settings.recoveryAudio)
        XCTAssertNotNil(state.errorMessage)
    }

    @MainActor
    func testSuccessfulBehaviorSavesAndProfileManagement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path)
        let state = SettingsFixture(bridge: bridge)
        state.setAutoPaste(false)
        state.setShowOverlay(false)
        state.setSpeakerLabelsEnabled(true)
        XCTAssertFalse(state.autoPaste)
        XCTAssertFalse(state.showRecordingOverlay)
        XCTAssertTrue(state.speakerLabelsEnabled)
        XCTAssertFalse(try bridge.getAutoPaste())
        state.saveProfile("saved")
        XCTAssertEqual(state.listProfiles(), ["saved"])
        state.deleteProfile("saved")
        XCTAssertTrue(state.listProfiles().isEmpty)
        state.loadProfile("missing")
        XCTAssertNotNil(state.errorMessage)
    }
    @MainActor
    func testDeletedModeRepairsVisibleSelectionAndApplicationDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path)
        let state = SettingsFixture(bridge: bridge)
        state.saveMode(ModeConfig(name: "Custom", sttProvider: nil, llmProvider: nil, systemPrompt: nil, dictionaryEnabled: true))
        state.activeMode = "Custom"
        state.setAppModeDefault(bundleId: "test.editor", mode: "Custom")
        XCTAssertEqual(state.getAppModeDefaults().count, 1)
        state.deleteMode("Custom")
        XCTAssertEqual(state.activeMode, "dictation")
        XCTAssertTrue(state.getAppModeDefaults().isEmpty)
    }

}
