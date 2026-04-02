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

    // MARK: - Hotkey config

    /// Get current hotkey configuration.
    func getHotkeyConfig() -> HotkeyConfig {
        engine.getHotkeyConfig()
    }

    /// Set and persist hotkey configuration.
    func setHotkeyConfig(_ config: HotkeyConfig) throws {
        try engine.setHotkeyConfig(config: config)
    }

    /// Get the preferred audio source bundle ID.
    func getPreferredAudioSource() -> String? {
        engine.getPreferredAudioSource()
    }

    /// Set and persist the preferred audio source bundle ID.
    func setPreferredAudioSource(_ bundleId: String?) throws {
        try engine.setPreferredAudioSource(bundleId: bundleId)
    }

    /// Configure the LLM provider at runtime.
    func configureLlm(provider: String, baseUrl: String, model: String, apiKey: String?) throws {
        try engine.configureLlm(provider: provider, baseUrl: baseUrl, model: model, apiKey: apiKey)
    }

    /// Fetch available models from an LLM provider.
    func listLlmModels(provider: String, baseUrl: String, apiKey: String?) throws -> [String] {
        try engine.listLlmModels(provider: provider, baseUrl: baseUrl, apiKey: apiKey)
    }

    // MARK: - Model downloading

    /// Start downloading a model in the background.
    func startDownload(_ modelId: String) throws {
        try engine.startDownload(modelId: modelId)
    }

    /// Cancel an in-progress download.
    func cancelDownload() {
        engine.cancelDownload()
    }

    /// Get current download progress (poll on a timer).
    func getDownloadProgress() -> DownloadProgress {
        engine.getDownloadProgress()
    }

    /// Delete a downloaded model's files.
    func deleteModel(_ modelId: String) throws {
        try engine.deleteModel(modelId: modelId)
    }

    // MARK: - Session-based chunked transcription (meetings / long-form)

    /// Start a new chunked transcription session.
    func startSession(sessionId: String) throws {
        try engine.startSession(sessionId: sessionId)
    }

    /// Process one audio chunk within a session.
    /// Dictionary + LLM processing is applied per-chunk to avoid
    /// accumulating a huge transcript for the LLM at session end.
    func processChunk(
        sessionId: String,
        audioSamples: [Float],
        sampleRate: UInt32,
        chunkIndex: UInt32,
        mode: String,
        context: AppContextInfo?
    ) throws -> ChunkResult {
        let ctx = context.map {
            AppContext(
                appBundleId: $0.appBundleId,
                appName: $0.appName,
                selectedText: $0.selectedText,
                windowTitle: $0.windowTitle
            )
        }
        return try engine.processChunk(
            sessionId: sessionId,
            audioSamples: audioSamples,
            sampleRate: sampleRate,
            chunkIndex: chunkIndex,
            mode: mode,
            context: ctx
        )
    }

    /// Finish a session and return the accumulated result.
    func finishSession(
        sessionId: String,
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
        return try engine.finishSession(
            sessionId: sessionId,
            mode: mode,
            context: ctx
        )
    }

    /// Cancel and discard a session.
    func cancelSession(sessionId: String) {
        engine.cancelSession(sessionId: sessionId)
    }

    // MARK: - Transcription history

    /// List transcriptions with optional filtering and search.
    func listTranscriptions(query: TranscriptionQuery) throws -> [StoredTranscription] {
        try engine.listTranscriptions(query: query)
    }

    /// Full-text search across all transcriptions.
    func searchTranscriptions(searchText: String) throws -> [StoredTranscription] {
        try engine.searchTranscriptions(searchText: searchText)
    }

    /// Get a single transcription by ID.
    func getTranscription(id: String) throws -> StoredTranscription {
        try engine.getTranscription(id: id)
    }

    /// Update the title of a transcription.
    func updateTranscriptionTitle(id: String, title: String) throws {
        try engine.updateTranscriptionTitle(id: id, title: title)
    }

    /// Delete a transcription from history.
    func deleteTranscription(id: String) throws {
        try engine.deleteTranscription(id: id)
    }

    /// Delete multiple transcriptions. Returns the number deleted.
    func deleteTranscriptions(ids: [String]) throws -> UInt32 {
        try engine.deleteTranscriptions(ids: ids)
    }

    /// Get timestamp segments for a transcription (for timeline display).
    func getTranscriptionSegments(id: String) throws -> [TimestampedSegment] {
        try engine.getTranscriptionSegments(id: id)
    }
}
