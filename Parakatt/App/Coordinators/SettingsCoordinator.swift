import Combine
import Foundation

/// User preferences — the persisted bag of toggles + LLM connection info.
///
/// Owns the @Published fields that drive Settings UI bindings. AppState
/// holds a strong reference and forwards objectWillChange so the rest
/// of the app can still observe via the AppState boundary.
///
/// LLM credentials route through Keychain on write — never serialised
/// into the TOML config — which is why `llmApiKey` has a didSet hook
/// here rather than living solely in the Rust config layer.
@MainActor
final class SettingsCoordinator: ObservableObject {
    private let secrets: SecretStoring

    init(secrets: SecretStoring = MacSecretStore()) {
        self.secrets = secrets
    }

    // MARK: - Behavior toggles

    @Published var autoPaste = true
    @Published var showRecordingOverlay = true
    @Published var debugMode = false
    @Published var speakerLabelsEnabled = false
    @Published var activeMode = "dictation"

    // MARK: - LLM connection

    @Published var llmProvider: String = ""
    @Published var llmBaseUrl: String = "http://localhost:11434"
    @Published var llmModel: String = "llama3.2"
    @Published var llmApiKey: String = "" {
        didSet {
            // Persist API key to Keychain instead of config file.
            secrets.set(llmApiKey, forKey: "llm-api-key")
        }
    }

    /// Pull the API key out of Keychain (called at startup so the
    /// in-memory copy matches what's persisted).
    func loadLlmApiKeyFromKeychain() {
        if let key = secrets.get("llm-api-key") {
            llmApiKey = key
        }
    }

    func loadBehaviorSettings(bridge: CoreBridge?) {
        if let ap = try? bridge?.getAutoPaste() { autoPaste = ap }
        if let so = try? bridge?.getShowOverlay() { showRecordingOverlay = so }
        if let dm = try? bridge?.getDebugMode() { debugMode = dm }
        if let sl = try? bridge?.getSpeakerLabelsEnabled() { speakerLabelsEnabled = sl }
    }

    func configureLlm(bridge: CoreBridge?) {
        do {
            let key = llmApiKey.isEmpty ? nil : llmApiKey
            try bridge?.configureLlm(
                provider: llmProvider,
                baseUrl: llmBaseUrl,
                model: llmModel,
                apiKey: key
            )
            NSLog("[Parakatt] LLM configured: provider=%@, model=%@", llmProvider, llmModel)
        } catch {
            NSLog("[Parakatt] LLM config failed: %@", error.localizedDescription)
        }
    }

    func testLlmConnection(bridge: CoreBridge?) -> String {
        do {
            return try bridge?.testLlmConnection() ?? "No engine"
        } catch {
            return error.localizedDescription
        }
    }

    func fetchLlmModels(bridge: CoreBridge?) -> [String] {
        guard !llmProvider.isEmpty else { return [] }
        do {
            let key = llmApiKey.isEmpty ? nil : llmApiKey
            return try bridge?.listLlmModels(
                provider: llmProvider,
                baseUrl: llmBaseUrl,
                apiKey: key
            ) ?? []
        } catch {
            NSLog("[Parakatt] Failed to list models: %@", error.localizedDescription)
            return []
        }
    }

    func setAutoPaste(_ enabled: Bool, bridge: CoreBridge?) {
        autoPaste = enabled
        do {
            try bridge?.setAutoPaste(enabled)
        } catch {
            NSLog("[Parakatt] Failed to save auto_paste setting: %@", error.localizedDescription)
        }
    }

    func setDebugMode(_ enabled: Bool, bridge: CoreBridge?) {
        debugMode = enabled
        do {
            try bridge?.setDebugMode(enabled)
        } catch {
            NSLog("[Parakatt] Failed to save debug_mode setting: %@", error.localizedDescription)
        }
    }

    func setSpeakerLabelsEnabled(_ enabled: Bool, bridge: CoreBridge?) {
        speakerLabelsEnabled = enabled
        do {
            try bridge?.setSpeakerLabelsEnabled(enabled)
        } catch {
            NSLog("[Parakatt] Failed to save speaker_labels_enabled setting: %@", error.localizedDescription)
        }
    }

    func setShowOverlay(_ enabled: Bool, bridge: CoreBridge?) {
        showRecordingOverlay = enabled
        do {
            try bridge?.setShowOverlay(enabled)
        } catch {
            NSLog("[Parakatt] Failed to save show_overlay setting: %@", error.localizedDescription)
        }
    }
}
