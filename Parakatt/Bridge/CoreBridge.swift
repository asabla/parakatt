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

    // MARK: - Behavior settings

    /// Get whether debug logging is enabled.
    func getDebugMode() throws -> Bool {
        try engine.getDebugMode()
    }

    /// Enable or disable debug logging.
    func setDebugMode(_ enabled: Bool) throws {
        try engine.setDebugMode(enabled: enabled)
    }

    /// Get whether auto-paste after transcription is enabled.
    func getAutoPaste() throws -> Bool {
        try engine.getAutoPaste()
    }

    /// Enable or disable auto-paste after transcription.
    func setAutoPaste(_ enabled: Bool) throws {
        try engine.setAutoPaste(enabled: enabled)
    }

    /// Get whether the recording overlay is shown.
    func getShowOverlay() throws -> Bool {
        try engine.getShowOverlay()
    }

    /// Enable or disable the recording overlay.
    func setShowOverlay(_ enabled: Bool) throws {
        try engine.setShowOverlay(enabled: enabled)
    }

    // MARK: - Hotkey config

    /// Get current hotkey configuration.
    func getHotkeyConfig() throws -> HotkeyConfig {
        try engine.getHotkeyConfig()
    }

    /// Set and persist hotkey configuration.
    func setHotkeyConfig(_ config: HotkeyConfig) throws {
        try engine.setHotkeyConfig(config: config)
    }

    /// Get the preferred audio source bundle ID.
    func getPreferredAudioSource() throws -> String? {
        try engine.getPreferredAudioSource()
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

    /// Test the current LLM connection.
    func testLlmConnection() throws -> String {
        try engine.testLlmConnection()
    }

    // MARK: - Modes

    /// Get per-app mode defaults as (bundleId, modeName) pairs.
    func getAppModeDefaults() throws -> [(String, String)] {
        let raw = try engine.getAppModeDefaults()
        return raw.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        }
    }

    /// Set a per-app mode default. Pass empty mode to remove.
    func setAppModeDefault(bundleId: String, mode: String) throws {
        try engine.setAppModeDefault(bundleId: bundleId, mode: mode)
    }

    /// Resolve which mode to use for a given app, falling back to the global default.
    func resolveModeForApp(bundleId: String?) throws -> String {
        try engine.resolveModeForApp(bundleId: bundleId)
    }

    // MARK: - Profiles

    /// List available config profile names.
    func listProfiles() -> [String] {
        engine.listProfiles()
    }

    /// Save the current config as a named profile.
    func saveProfile(_ name: String) throws {
        try engine.saveProfile(name: name)
    }

    /// Load a named profile, replacing the current config.
    func loadProfile(_ name: String) throws {
        try engine.loadProfile(name: name)
    }

    /// Delete a named profile.
    func deleteProfile(_ name: String) throws {
        try engine.deleteProfile(name: name)
    }

    /// Save or update a custom mode.
    func saveMode(_ mode: ModeConfig) throws {
        try engine.saveMode(mode: mode)
    }

    /// Delete a custom mode by name. Built-in modes cannot be deleted.
    func deleteMode(_ name: String) throws {
        try engine.deleteMode(name: name)
    }

    // MARK: - Statistics

    /// Get usage statistics as (label, value) pairs.
    func getStatistics() throws -> [(String, String)] {
        let raw = try engine.getStatistics()
        return raw.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        }
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
    func getDownloadProgress() throws -> DownloadProgress {
        try engine.getDownloadProgress()
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
    ///
    /// `chunkOverlapSecs` lets the caller declare how many seconds at
    /// the start of `audioSamples` are a re-encoding of audio the
    /// previous chunk already covered. Pass > 0 to use the
    /// authoritative time-based dedup (NeMo middle-token style),
    /// pass 0 to fall back to text-based dedup.
    func processChunk(
        sessionId: String,
        audioSamples: [Float],
        sampleRate: UInt32,
        chunkIndex: UInt32,
        chunkOverlapSecs: Double = 0.0,
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
        if chunkOverlapSecs > 0.0 {
            return try engine.processChunkWithOverlap(
                sessionId: sessionId,
                audioSamples: audioSamples,
                sampleRate: sampleRate,
                chunkIndex: chunkIndex,
                chunkOverlapSecs: chunkOverlapSecs,
                mode: mode,
                context: ctx
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
        context: AppContextInfo?,
        source: String? = nil
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
            context: ctx,
            source: source
        )
    }

    /// Get the running accumulated transcript for a session, on demand.
    /// `processChunk` no longer returns it on every call to avoid the
    /// per-chunk full-string clone; pull it via this when you actually
    /// need to refresh a UI surface.
    func getSessionText(sessionId: String) throws -> String {
        try engine.getSessionText(sessionId: sessionId)
    }

    // MARK: - Streaming preview (cache-aware Nemotron path)

    /// Whether the streaming/live-preview model is loaded. Used to
    /// decide whether the live-preview worker should run.
    func isStreamingModelLoaded() -> Bool {
        engine.isStreamingModelLoaded()
    }

    /// Native chunk size in samples for the loaded streaming model.
    /// 0 if no streaming model is loaded.
    func streamingNativeChunkSamples() -> UInt32 {
        engine.streamingNativeChunkSamples()
    }

    /// Open a new streaming preview session for the given id.
    func startStreamingSession(sessionId: String) throws {
        try engine.startStreamingSession(sessionId: sessionId)
    }

    /// Feed a chunk of audio to a streaming session. The Rust side
    /// runs LocalAgreement-2 internally and returns committed +
    /// tentative slices ready for the UI.
    func feedStreamingChunk(
        sessionId: String,
        audioSamples: [Float]
    ) throws -> StreamingChunkResult {
        try engine.feedStreamingChunk(
            sessionId: sessionId,
            audioSamples: audioSamples
        )
    }

    /// Reset a streaming session in place (model state + LA-2 buffer).
    func resetStreamingSession(sessionId: String) throws {
        try engine.resetStreamingSession(sessionId: sessionId)
    }

    /// Close and discard a streaming session, returning final text.
    func finishStreamingSession(sessionId: String) throws -> String {
        try engine.finishStreamingSession(sessionId: sessionId)
    }

    /// Cancel and discard a streaming session.
    func cancelStreamingSession(sessionId: String) {
        engine.cancelStreamingSession(sessionId: sessionId)
    }

    // MARK: - Buffered preview (Nemotron-absent fallback)
    //
    // When the cache-aware streaming model isn't loaded the live
    // preview falls back to running Parakeet TDT on a growing audio
    // tail every few hundred milliseconds. These calls pipe each
    // pass through LocalAgreement-2 so the user STILL sees the
    // committed/tentative split instead of a flickering raw
    // transcript.

    func bufferedPreviewStart(sessionId: String) throws {
        try engine.bufferedPreviewStart(sessionId: sessionId)
    }

    func bufferedPreviewUpdate(
        sessionId: String,
        audioSamples: [Float],
        sampleRate: UInt32
    ) throws -> StreamingChunkResult {
        try engine.bufferedPreviewUpdate(
            sessionId: sessionId,
            audioSamples: audioSamples,
            sampleRate: sampleRate
        )
    }

    func bufferedPreviewFinish(sessionId: String) throws -> String {
        try engine.bufferedPreviewFinish(sessionId: sessionId)
    }

    func bufferedPreviewReset(sessionId: String) throws {
        try engine.bufferedPreviewReset(sessionId: sessionId)
    }

    func bufferedPreviewCancel(sessionId: String) {
        engine.bufferedPreviewCancel(sessionId: sessionId)
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
