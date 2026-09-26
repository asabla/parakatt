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
    // MARK: - Behavior toggles

    @Published var autoPaste = true
    @Published var showRecordingOverlay = true
    @Published var debugMode = false
    @Published var recoveryAudio = false
    @Published var llmContextEnabled = false
    @Published var speakerLabelsEnabled = false
    @Published var activeMode = "dictation"

    // MARK: - LLM connection

    @Published var llmProvider: String = "" {
        didSet { if oldValue != llmProvider { loadLlmApiKeyFromKeychain() } }
    }
    var credentialAccountResolver: ((String) -> String)?
    private var credentialAccount: String { credentialAccountResolver?(llmProvider) ?? "llm-api-key-\(llmProvider)" }
    private var loadingCredential = false
    @Published var credentialError: String?
    @Published var llmBaseUrl: String = "http://localhost:11434"
    @Published var llmModel: String = "llama3.2"
    @Published var llmApiKey: String = "" {
        didSet {
            // Persist API key to Keychain instead of config file.
            if !loadingCredential && ["openai", "anthropic"].contains(llmProvider) {
                credentialError = KeychainService.set(llmApiKey, forKey: credentialAccount) ? nil : "Could not store the API key in Keychain."
            }
        }
    }

    /// Pull the API key out of Keychain (called at startup so the
    /// in-memory copy matches what's persisted).
    func loadLlmApiKeyFromKeychain() {
        loadingCredential = true
        credentialError = nil
        llmApiKey = KeychainService.get(credentialAccount) ?? ""
        loadingCredential = false
    }
}
