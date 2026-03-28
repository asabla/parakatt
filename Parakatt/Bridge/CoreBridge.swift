import Foundation
import ParakattCore

/// Thin wrapper around the UniFFI-generated Rust Engine.
///
/// Adapts between the Swift service layer and the generated Rust bindings.
class CoreBridge {
    private let engine: Engine

    init(modelsDir: String, configDir: String, activeMode: String = "dictation") throws {
        let config = EngineConfig(
            modelsDir: modelsDir,
            configDir: configDir,
            activeSttModel: nil,
            activeLlmProvider: nil,
            activeMode: activeMode
        )
        self.engine = try Engine(engineConfig: config)
    }

    /// Run the full pipeline: audio → STT → dictionary → LLM → text.
    func transcribe(
        audioSamples: [Float],
        sampleRate: UInt32,
        mode: String,
        context: AppContextInfo?
    ) throws -> TranscriptionResult {
        let ctx = context.map {
            AppContext(
                appBundleId: $0.appBundleId,
                appName: $0.appName,
                selectedText: $0.selectedText,
                windowTitle: $0.windowTitle
            )
        }
        return try engine.transcribe(
            audioSamples: audioSamples,
            sampleRate: sampleRate,
            mode: mode,
            context: ctx
        )
    }

    /// Load an STT model by ID (e.g. "whisper-base.en").
    func loadModel(_ modelId: String) throws {
        try engine.loadModel(modelId: modelId)
    }

    /// Unload the current STT model.
    func unloadModel() {
        engine.unloadModel()
    }

    /// Check if an STT model is loaded and ready.
    func isModelLoaded() -> Bool {
        engine.isModelLoaded()
    }

    /// List available models with download status.
    func listModels() -> [ModelInfo] {
        engine.listModels()
    }

    /// List configured modes.
    func listModes() -> [ModeConfig] {
        engine.listModes()
    }

    /// Update dictionary rules.
    func setDictionaryRules(_ rules: [ReplacementRule]) throws {
        try engine.setDictionaryRules(rules: rules)
    }

    /// Get current dictionary rules.
    func getDictionaryRules() -> [ReplacementRule] {
        engine.getDictionaryRules()
    }
}
