import AppKit
import Combine
import Foundation
import HotKey
import ParakattCore

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
    var onErrorMessage: ((String?) -> Void)?

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

    func listModes(bridge: CoreBridge?) -> [ModeConfig] {
        bridge?.listModes() ?? []
    }

    func saveMode(_ mode: ModeConfig, bridge: CoreBridge?) {
        do {
            try bridge?.saveMode(mode)
        } catch {
            onErrorMessage?("Failed to save mode: \(error.localizedDescription)")
        }
    }

    func deleteMode(_ name: String, bridge: CoreBridge?) {
        do {
            try bridge?.deleteMode(name)
        } catch {
            onErrorMessage?("Failed to delete mode: \(error.localizedDescription)")
        }
    }

    func listProfiles(bridge: CoreBridge?) -> [String] {
        bridge?.listProfiles() ?? []
    }

    func saveProfile(_ name: String, bridge: CoreBridge?) {
        do {
            try bridge?.saveProfile(name)
            NSLog("[Parakatt] Saved profile: %@", name)
        } catch {
            onErrorMessage?("Failed to save profile: \(error.localizedDescription)")
        }
    }

    func loadProfile(_ name: String, bridge: CoreBridge?) {
        do {
            try bridge?.loadProfile(name)
            // Reload settings from the new config.
            loadBehaviorSettings(bridge: bridge)
            loadLlmApiKeyFromKeychain()
            NSLog("[Parakatt] Loaded profile: %@", name)
        } catch {
            onErrorMessage?("Failed to load profile: \(error.localizedDescription)")
        }
    }

    func deleteProfile(_ name: String, bridge: CoreBridge?) {
        do {
            try bridge?.deleteProfile(name)
        } catch {
            onErrorMessage?("Failed to delete profile: \(error.localizedDescription)")
        }
    }

    func getAppModeDefaults(bridge: CoreBridge?) -> [(String, String)] {
        do {
            return try bridge?.getAppModeDefaults() ?? []
        } catch {
            NSLog("[Parakatt] Failed to get app mode defaults: %@", error.localizedDescription)
            return []
        }
    }

    func setAppModeDefault(bundleId: String, mode: String, bridge: CoreBridge?) {
        do {
            try bridge?.setAppModeDefault(bundleId: bundleId, mode: mode)
        } catch {
            NSLog("[Parakatt] Failed to set app mode default: %@", error.localizedDescription)
        }
    }

    func resolveEffectiveMode(for context: AppContextInfo?, bridge: CoreBridge?) -> String {
        if let bundleId = context?.appBundleId,
           let resolved = try? bridge?.resolveModeForApp(bundleId: bundleId) {
            return resolved
        }
        return activeMode
    }

    func getStatistics(bridge: CoreBridge?) -> [(String, String)] {
        do {
            return try bridge?.getStatistics() ?? []
        } catch {
            NSLog("[Parakatt] Failed to get statistics: %@", error.localizedDescription)
            return []
        }
    }

    func getDictionaryRules(bridge: CoreBridge?) -> [ParakattCore.ReplacementRule] {
        bridge?.getDictionaryRules() ?? []
    }

    func setDictionaryRules(_ rules: [ParakattCore.ReplacementRule], bridge: CoreBridge?) {
        do {
            try bridge?.setDictionaryRules(rules)
            NSLog("[Parakatt] Dictionary updated: %d rules", rules.count)
        } catch {
            NSLog("[Parakatt] Failed to set dictionary rules: %@", error.localizedDescription)
        }
    }

    /// Load hotkey config from the Rust engine. Returns parsed key/modifiers/mode.
    func loadHotkeyConfig(bridge: CoreBridge?) -> (key: Key, modifiers: NSEvent.ModifierFlags, mode: String) {
        guard let bridge else {
            return (.space, [.option], "hold")
        }
        guard let config = try? bridge.getHotkeyConfig() else {
            return (.space, [.option], "hold")
        }
        let key = HotkeyService.keyFromString(config.key) ?? .space
        let modifiers = HotkeyService.modifiersFromStrings(config.modifiers)
        let mode = config.mode
        return (key, modifiers.isEmpty ? [.option] : modifiers, mode)
    }

    /// Save hotkey config and reconfigure the service.
    func setHotkey(
        key: Key,
        modifiers: NSEvent.ModifierFlags,
        mode: String,
        bridge: CoreBridge?,
        hotkeyService: HotkeyService?
    ) {
        let keyStr = HotkeyService.stringFromKey(key)
        let modStrs = HotkeyService.stringsFromModifiers(modifiers)
        let config = HotkeyConfig(key: keyStr, modifiers: modStrs, mode: mode)

        do {
            try bridge?.setHotkeyConfig(config)
        } catch {
            NSLog("[Parakatt] Failed to save hotkey config: %@", error.localizedDescription)
        }

        hotkeyService?.reconfigure(key: key, modifiers: modifiers, mode: mode)
        NSLog("[Parakatt] Hotkey updated: %@ + %@ (%@)", modStrs.joined(separator: "+"), keyStr, mode)
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
