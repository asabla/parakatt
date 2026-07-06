import AppKit
import Combine
import HotKey
import os.log
import ParakattCore

private let logger = Logger(subsystem: "com.parakatt.app", category: "engine")
private let signpostLog = OSLog(subsystem: "com.parakatt.app", category: .pointsOfInterest)

/// Observable application state shared across the UI.
///
/// Coordinates recording, transcription, and text insertion.
///
/// `@MainActor` is required: this class owns `@Published` properties
/// that drive SwiftUI surfaces, and historically there were ad-hoc
/// `DispatchQueue.main.async` calls scattered throughout to keep
/// updates on the main thread. Pinning the whole class to `@MainActor`
/// lets the compiler enforce that — any background-thread call site
/// has to explicitly hop back via `Task { @MainActor in … }` or
/// `DispatchQueue.main.async`.
@MainActor
class AppState: ObservableObject {
    // MARK: - Coordinators
    //
    // Long-term we want @Published state grouped by concern. PR 5 of
    // the code-review backlog lands the SettingsCoordinator and
    // ContextCoordinator (the smallest, most cohesive groups) plus
    // skeletons for Recording / Meeting / Model. Follow-up PRs fill
    // out the remaining three and migrate their state out of AppState.
    //
    // AppState forwards each coordinator's objectWillChange into its
    // own so SwiftUI surfaces that observe `appState` keep updating
    // when coordinator state changes. Views that want a Binding into
    // a coordinator-owned field should use `$appState.settings.foo`
    // rather than going through a computed shim on AppState.
    @Published var settings: SettingsCoordinator
    @Published var context = ContextCoordinator()
    @Published var recording = RecordingCoordinator()
    @Published var meeting = MeetingCoordinator()
    @Published var model = ModelCoordinator()
    private let history = HistoryCoordinator()
    private let audioInput = AudioInputCoordinator()
    private let notifications = NotificationCoordinator()
    private let permissions = PermissionCoordinator()
    private let diagnostics = DiagnosticsCoordinator()
    private let textOutput = TextOutputCoordinator()
    private let livePreview = LivePreviewCoordinator()
    private let engine = EngineCoordinator()

    private var coordinatorCancellables = Set<AnyCancellable>()

    // MARK: - Recording state (lives on RecordingCoordinator)
    //
    // Computed shims keep every existing `appState.isRecording = …`
    // call site working without touching it. RecordingCoordinator
    // owns the @Published storage; AppState's init() already forwards
    // its objectWillChange so SwiftUI keeps re-rendering.

    var isRecording: Bool {
        get { recording.isRecording }
        set { recording.isRecording = newValue }
    }
    var isProcessing: Bool {
        get { recording.isProcessing }
        set { recording.isProcessing = newValue }
    }
    var lastTranscription: String? {
        get { recording.lastTranscription }
        set { recording.lastTranscription = newValue }
    }
    var liveTranscription: String? {
        get { recording.liveTranscription }
        set { recording.liveTranscription = newValue }
    }
    var currentAudioLevel: Float {
        get { recording.currentAudioLevel }
        set { recording.currentAudioLevel = newValue }
    }
    var silenceDetected: Bool {
        get { recording.silenceDetected }
        set { recording.silenceDetected = newValue }
    }
    var audioClippingDetected: Bool {
        get { recording.audioClippingDetected }
        set { recording.audioClippingDetected = newValue }
    }
    var livePreviewCommitted: String {
        get { recording.livePreviewCommitted }
        set { recording.livePreviewCommitted = newValue }
    }
    var livePreviewTentative: String {
        get { recording.livePreviewTentative }
        set { recording.livePreviewTentative = newValue }
    }

    // MARK: - Published state (still on AppState)

    @Published var errorMessage: String?

    // MARK: - Model state (lives on ModelCoordinator)

    var isModelLoaded: Bool {
        get { model.isModelLoaded }
        set { model.isModelLoaded = newValue }
    }
    var activeModelId: String? {
        get { model.activeModelId }
        set { model.activeModelId = newValue }
    }
    var needsModelDownload: Bool {
        get { model.needsModelDownload }
        set { model.needsModelDownload = newValue }
    }
    var isDownloading: Bool {
        get { model.isDownloading }
        set { model.isDownloading = newValue }
    }
    var downloadProgress: ParakattCore.DownloadProgress? {
        get { model.downloadProgress }
        set { model.downloadProgress = newValue }
    }

    // MARK: - Meeting state (lives on MeetingCoordinator)

    var isMeetingActive: Bool {
        get { meeting.isMeetingActive }
        set { meeting.isMeetingActive = newValue }
    }
    var isMeetingPaused: Bool {
        get { meeting.isMeetingPaused }
        set { meeting.isMeetingPaused = newValue }
    }
    var meetingElapsedTime: TimeInterval {
        get { meeting.meetingElapsedTime }
        set { meeting.meetingElapsedTime = newValue }
    }
    var meetingTranscription: String? {
        get { meeting.meetingTranscription }
        set { meeting.meetingTranscription = newValue }
    }
    var meetingLatestChunk: String? {
        get { meeting.meetingLatestChunk }
        set { meeting.meetingLatestChunk = newValue }
    }
    var meetingSegments: [TimestampedSegment] {
        get { meeting.meetingSegments }
        set { meeting.meetingSegments = newValue }
    }
    var meetingLatestChunkStartSecs: Double? {
        get { meeting.meetingLatestChunkStartSecs }
        set { meeting.meetingLatestChunkStartSecs = newValue }
    }
    var meetingAudioStatus: MeetingAudioStatus {
        get { meeting.meetingAudioStatus }
        set { meeting.meetingAudioStatus = newValue }
    }
    var meetingMicLevel: Float {
        get { meeting.meetingMicLevel }
        set { meeting.meetingMicLevel = newValue }
    }
    var meetingFirstChunkSecs: Double { meeting.meetingFirstChunkSecs }
    var meetingChunkIntervalSecs: Double { meeting.meetingChunkIntervalSecs }

    // Behavior settings live on SettingsCoordinator; these computed
    // shims keep existing call sites (`appState.autoPaste = ...` etc.)
    // working without touching every reference.
    var autoPaste: Bool {
        get { settings.autoPaste }
        set { settings.autoPaste = newValue }
    }
    var showRecordingOverlay: Bool {
        get { settings.showRecordingOverlay }
        set { settings.showRecordingOverlay = newValue }
    }
    var debugMode: Bool {
        get { settings.debugMode }
        set { settings.debugMode = newValue }
    }
    var speakerLabelsEnabled: Bool {
        get { settings.speakerLabelsEnabled }
        set { settings.speakerLabelsEnabled = newValue }
    }
    var activeMode: String {
        get { settings.activeMode }
        set { settings.activeMode = newValue }
    }

    // Audio source selection lives on ContextCoordinator.
    var selectedAudioSourcePID: pid_t? {
        get { context.selectedAudioSourcePID }
        set { context.selectedAudioSourcePID = newValue }
    }
    var selectedAudioSourceName: String? {
        get { context.selectedAudioSourceName }
        set { context.selectedAudioSourceName = newValue }
    }

    // MARK: - Services

    private let environment: PlatformEnvironment

    /// Set by AppDelegate after init; used for hotkey reconfiguration.
    var hotkeyService: HotkeyService?
    private var audioCaptureService: AudioCapturing?
    private var textInsertionService: TextInserting?
    private var contextService: AppContextProviding?

    // MARK: - Engine bridge

    private var bridge: CoreBridge? { engine.bridge }
    private var engineReady: Bool { engine.isReady }

    // MARK: - Lifecycle

    init(environment: PlatformEnvironment = MacAppEnvironment()) {
        self.environment = environment
        self.settings = SettingsCoordinator(secrets: environment.secrets)
        self.settings.onErrorMessage = { [weak self] message in
            self?.errorMessage = message
        }
        self.model.onErrorMessage = { [weak self] message in
            self?.errorMessage = message
        }
        self.meeting.onAudioWarning = { [weak self] message in
            guard let self, self.errorMessage == nil else { return }
            self.errorMessage = message
        }

        // Forward each coordinator's objectWillChange into AppState's
        // own so SwiftUI surfaces that observe `appState` (rather than
        // a specific coordinator) keep updating when coordinator state
        // changes. Without this, computed shims on AppState that read
        // through to a coordinator wouldn't trigger view invalidation.
        for inner in [
            settings.objectWillChange,
            context.objectWillChange,
            recording.objectWillChange,
            meeting.objectWillChange,
            model.objectWillChange,
        ] {
            inner
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &coordinatorCancellables)
        }
    }

    /// Initialize the Rust engine, audio services, and load settings from config.
    func initializeEngine() {
        // Set up file logging
        FileLogService.shared.logStartup()

        // Set up services
        textInsertionService = environment.makeTextInserter()
        contextService = environment.makeContextProvider()
        notifications.requestAuthorization(environment: environment)

        // Create audio capture once — reused across all recording sessions
        let capture = environment.makeAudioCapture()
        capture.onAudioSamples = { [weak self] samples in
            self?.appendAudioSamples(samples)
        }
        audioCaptureService = capture

        NSLog("[Parakatt] Initializing engine...")

        // Create the engine (lightweight — no model loaded yet)
        do {
            let bridge = try engine.initialize(
                modelsDir: environment.paths.modelsDirectory.path,
                configDir: environment.paths.configDirectory.path,
                activeMode: activeMode
            )
            NSLog("[Parakatt] Engine created")

            // Build the live preview service. It's a no-op until start()
            // is called and gracefully falls back if no streaming model is loaded.
            livePreview.configure(bridge: bridge) { [weak self] committed, tentative, _ in
                guard let self else { return }
                self.recording.applyPreviewText(committed: committed, tentative: tentative)
            }

            // Load behavior settings from config
            settings.loadBehaviorSettings(bridge: bridge)

            // Load API key from Keychain (not config file)
            loadLlmApiKeyFromKeychain()

            // Load preferred audio source from config
            context.restorePreferredAudioSource(bridge: bridge, runningApps: environment.runningApps)
        } catch {
            errorMessage = "Failed to initialize engine: \(error.localizedDescription)"
            NSLog("[Parakatt] Engine init failed: \(error)")
            return
        }

        model.loadDownloadedModels(bridge: bridge)
    }

    /// Clean up all running sessions and audio capture on app termination.
    func shutdown() {
        stopRecording()
        if let sessionId = recording.currentPttSessionId() {
            bridge?.cancelSession(sessionId: sessionId)
            recording.clearPttSession()
        }
        if #available(macOS 14.2, *) {
            cancelMeeting()
        }
        model.shutdown()
        engine.shutdown()
    }

    // MARK: - Recording

    /// Start a push-to-talk recording session via AVAudioEngine.
    func startRecording() {
        guard recording.canStartRecording() else {
            NSLog("[Parakatt] startRecording called but already recording or draining — ignoring")
            return
        }
        guard engineReady else {
            errorMessage = "Cannot record — download and load a model in Settings first"
            NSLog("[Parakatt] Cannot record: engine not ready (modelLoaded=%d)", isModelLoaded ? 1 : 0)
            return
        }

        // Set immediately after guard to prevent race with rapid start/stop.
        isRecording = true

        recording.resetForNewRecording()

        do {
            try audioCaptureService?.startCapture()
            recording.clearPreviewDisplay()
            errorMessage = nil

            // Try to start the cache-aware streaming preview. If
            // the streaming model isn't loaded (non-English user
            // who didn't download Nemotron, or first launch), this
            // gracefully falls back to the buffered v3 + LA-2 path
            // via the throwaway streaming preview below.
            if livePreview.startIfAvailable() {
                NSLog("[Parakatt] Live preview: streaming path active")
            }

            // Start throwaway buffered preview for immediate feedback.
            // This is the fallback path for users without the streaming
            // model, AND it runs alongside the streaming preview as a
            // safety net while the streaming model warms up.
            recording.startStreamingUpdates(interval: recording.streamingInterval) { [weak self] in
                self?.updateLiveTranscription()
            }

            // After the configured grace period, transition to incremental session-based processing.
            recording.startPttTransitionTimer(delay: recording.firstChunkDelaySecs) { [weak self] in
                self?.startIncrementalSession()
            }

            NSLog("[Parakatt] Recording STARTED (modelLoaded=%d, incremental after %.0fs)",
                  isModelLoaded ? 1 : 0, recording.firstChunkDelaySecs)
        } catch {
            isRecording = false
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            NSLog("[Parakatt] Recording FAILED: %@", error.localizedDescription)
        }
    }

    /// Stop recording and process the captured audio through the STT pipeline.
    func stopRecording() {
        guard isRecording else { return }

        recording.stopPttChunkTimer()
        recording.stopStreamingUpdates()
        isRecording = false
        currentAudioLevel = 0
        recording.beginCaptureDrain()

        // Keep audio capture running briefly so the hardware buffer can drain,
        // then stop capture and process the tail.
        DispatchQueue.main.asyncAfter(deadline: .now() + recording.captureDrainDelaySecs) { [weak self] in
            self?.finishStopRecording()
        }
    }

    /// Called after the capture drain grace period to stop capture and process remaining audio.
    private func finishStopRecording() {
        audioCaptureService?.stopCapture()
        // Re-prewarm so the next hotkey press doesn't pay the macOS
        // mic cold-start cost (which can be 2-5s after a few seconds
        // of inactivity). The pre-warm fills a 500ms ring that the
        // next startCapture() drains as pre-roll.
        //
        // Bounded to a 20s warm window: if no new recording starts
        // within that time the engine is torn down so the macOS
        // orange mic indicator actually turns off. Successive
        // dictations within the window stay warm (no cold-start).
        audioCaptureService?.prewarm(windowSecs: 20)
        recording.finishCaptureDrain()

        // Tear down the live preview session and grab its final
        // committed text. This becomes the canonical preview while
        // the commit pipeline finishes processing the buffer tail.
        if livePreview.isActive {
            let finalText = livePreview.stop()
            recording.applyFinalPreviewText(finalText)
        }

        // Also tear down the buffered preview LA-2 session if it
        // was used (when no streaming model was loaded).
        if let bpId = recording.takeBufferedPreviewSessionId() {
            let final = (try? bridge?.bufferedPreviewFinish(sessionId: bpId)) ?? ""
            recording.applyFinalPreviewText(final)
        }

        if let sessionId = recording.currentPttSessionId() {
            // Path B: incremental session was active — only process the tail.
            isProcessing = true
            // Keep liveTranscription visible while processing the tail.
            NSLog("[Parakatt] Recording stopped (incremental session, processing tail)")

            let remainingSamples = recording.drainBuffer()

            let context = contextService?.currentContext()
            let mode = activeMode
            let currentIndex = recording.currentPttChunkIndex()
            let sampleRate = recording.sampleRate

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self, let bridge = self.bridge else {
                    DispatchQueue.main.async { self?.isProcessing = false }
                    return
                }

                // Wait for any in-flight chunk to complete, then run the
                // tail under the same lock. Scoped so the lock is released
                // before the (potentially slow) finishSession call below,
                // even if a future edit adds an early return inside.
                do {
                    self.recording.withPttChunkLock {
                        if remainingSamples.count >= Int(sampleRate / 10) {
                            do {
                                let result = try bridge.processChunk(
                                    sessionId: sessionId,
                                    audioSamples: remainingSamples,
                                    sampleRate: sampleRate,
                                    chunkIndex: currentIndex,
                                    mode: mode,
                                    context: context
                                )
                                NSLog("[Parakatt] PTT final chunk %d: \"%@\"", currentIndex, result.text)
                            } catch {
                                NSLog("[Parakatt] PTT final chunk failed: %@", error.localizedDescription)
                            }
                        } else {
                            NSLog("[Parakatt] PTT tail too short (%.1fs), skipping",
                                  Double(remainingSamples.count) / Double(sampleRate))
                        }
                    }
                }

                // Finish the session.
                do {
                    let result = try bridge.finishSession(
                        sessionId: sessionId,
                        mode: mode,
                        context: context,
                        source: "push_to_talk"
                    )
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.liveTranscription = nil
                        self.lastTranscription = result.text
                        self.recording.setPttAccumulatedText(nil)
                        self.recording.clearPttSession()
                        self.errorMessage = nil

                        if !result.text.isEmpty {
                            self.errorMessage = self.textOutput.insertIfEnabled(
                                text: result.text,
                                autoPaste: self.autoPaste,
                                inserter: self.textInsertionService
                            )
                            NSLog("[Parakatt] PTT session result (%@, %.2fs): %@",
                                  mode, result.durationSecs, result.text)
                        }
                    }
                } catch {
                    bridge.cancelSession(sessionId: sessionId)
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.liveTranscription = nil
                        self.recording.setPttAccumulatedText(nil)
                        self.recording.clearPttSession()
                        self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                        NSLog("[Parakatt] PTT session finish FAILED: %@", error.localizedDescription)
                    }
                }
            }
        } else {
            // Path A: short recording, no session — single-shot processing.
            liveTranscription = nil
            NSLog("[Parakatt] Recording stopped (short, single-shot)")

            let samples = recording.drainBuffer()

            guard !samples.isEmpty else {
                NSLog("[Parakatt] stopRecording: NO AUDIO IN BUFFER")
                errorMessage = "No audio captured — check microphone permission in System Settings > Privacy & Security"
                return
            }

            let durationSecs = Double(samples.count) / Double(recording.sampleRate)
            guard durationSecs >= 0.5 else {
                NSLog("[Parakatt] Recording too short (%.2fs), discarding", durationSecs)
                errorMessage = "Recording too short — hold longer to capture audio"
                return
            }

            processAudio(samples)
        }
    }

    // MARK: - Diagnostics

    /// Record 3 seconds and log audio stats + transcription result.
    func runDiagnostic() {
        diagnostics.runMicDiagnostic(
            inputDevices: audioInput.listInputDevices(environment: environment),
            sampleRate: recording.sampleRate,
            startRecording: { [weak self] in self?.startRecording() },
            snapshotSamples: { [weak self] in self?.recording.snapshotBuffer() ?? [] },
            stopRecording: { [weak self] in self?.stopRecording() }
        )
    }

    /// Test system audio capture for 3 seconds and log results.
    @available(macOS 14.2, *)
    func runSystemAudioDiagnostic() {
        diagnostics.runSystemAudioDiagnostic(environment: environment)
    }

    // MARK: - LLM (delegates to SettingsCoordinator)

    var llmProvider: String {
        get { settings.llmProvider }
        set { settings.llmProvider = newValue }
    }
    var llmBaseUrl: String {
        get { settings.llmBaseUrl }
        set { settings.llmBaseUrl = newValue }
    }
    var llmModel: String {
        get { settings.llmModel }
        set { settings.llmModel = newValue }
    }
    var llmApiKey: String {
        get { settings.llmApiKey }
        set { settings.llmApiKey = newValue }
    }

    func loadLlmApiKeyFromKeychain() {
        settings.loadLlmApiKeyFromKeychain()
    }

    func configureLlm() {
        settings.configureLlm(bridge: bridge)
    }

    func testLlmConnection() -> String {
        settings.testLlmConnection(bridge: bridge)
    }

    func listModes() -> [ModeConfig] {
        settings.listModes(bridge: bridge)
    }

    func saveMode(_ mode: ModeConfig) {
        settings.saveMode(mode, bridge: bridge)
    }

    // MARK: - Profiles

    func listProfiles() -> [String] {
        settings.listProfiles(bridge: bridge)
    }

    func saveProfile(_ name: String) {
        settings.saveProfile(name, bridge: bridge)
    }

    func loadProfile(_ name: String) {
        settings.loadProfile(name, bridge: bridge)
    }

    func deleteProfile(_ name: String) {
        settings.deleteProfile(name, bridge: bridge)
    }

    func getAppModeDefaults() -> [(String, String)] {
        settings.getAppModeDefaults(bridge: bridge)
    }

    func setAppModeDefault(bundleId: String, mode: String) {
        settings.setAppModeDefault(bundleId: bundleId, mode: mode, bridge: bridge)
    }

    func deleteMode(_ name: String) {
        settings.deleteMode(name, bridge: bridge)
    }

    func getStatistics() -> [(String, String)] {
        settings.getStatistics(bridge: bridge)
    }

    func fetchLlmModels() -> [String] {
        settings.fetchLlmModels(bridge: bridge)
    }

    // MARK: - Dictionary

    func getDictionaryRules() -> [ParakattCore.ReplacementRule] {
        settings.getDictionaryRules(bridge: bridge)
    }

    func setDictionaryRules(_ rules: [ParakattCore.ReplacementRule]) {
        settings.setDictionaryRules(rules, bridge: bridge)
    }

    // MARK: - Input device

    func setInputDevice(uid: String?) {
        audioInput.setInputDevice(uid: uid, capture: audioCaptureService)
    }

    // MARK: - Hotkey configuration

    /// Load hotkey config from the Rust engine. Returns parsed key/modifiers/mode.
    func loadHotkeyConfig() -> (key: Key, modifiers: NSEvent.ModifierFlags, mode: String) {
        settings.loadHotkeyConfig(bridge: bridge)
    }

    /// Save hotkey config and reconfigure the service.
    func setHotkey(key: Key, modifiers: NSEvent.ModifierFlags, mode: String) {
        settings.setHotkey(key: key, modifiers: modifiers, mode: mode, bridge: bridge, hotkeyService: hotkeyService)
    }

    // MARK: - Behavior settings

    func setAutoPaste(_ enabled: Bool) {
        settings.setAutoPaste(enabled, bridge: bridge)
    }

    func setDebugMode(_ enabled: Bool) {
        settings.setDebugMode(enabled, bridge: bridge)
    }

    func setSpeakerLabelsEnabled(_ enabled: Bool) {
        settings.setSpeakerLabelsEnabled(enabled, bridge: bridge)
    }

    func setShowOverlay(_ enabled: Bool) {
        settings.setShowOverlay(enabled, bridge: bridge)
    }

    // MARK: - Audio source preference

    /// Persist the preferred audio source bundle ID.
    func setPreferredAudioSource(bundleId: String?) {
        context.setPreferredAudioSource(bundleId: bundleId, bridge: bridge)
    }

    func listRunningAudioApps() -> [AudioSourceApp] {
        context.listRunningAudioApps(runningApps: environment.runningApps)
    }

    func listInputDevices() -> [(uid: String, name: String, isDefault: Bool)] {
        audioInput.listInputDevices(environment: environment)
    }

    // MARK: - Meeting transcription

    /// Start a meeting transcription session.
    @available(macOS 14.2, *)
    func startMeeting() {
        guard !isMeetingActive else { return }
        guard engineReady, let bridge else {
            errorMessage = "Engine not ready — download and load a model in Settings first"
            return
        }

        let context = contextService?.currentContext()
        meeting.startSession(
            bridge: bridge,
            environment: environment,
            processID: selectedAudioSourcePID,
            sourceName: selectedAudioSourceName,
            mode: activeMode,
            context: context,
            speakerLabelsEnabled: speakerLabelsEnabled,
            onFinished: { [weak self] result in
                self?.sendTranscriptionNotification(preview: result.text, source: "meeting")
                NSLog("[Parakatt] Meeting finished: %.0fs, %d chars", result.durationSecs, result.text.count)
            },
            onError: { [weak self] message in
                self?.errorMessage = message
            },
            onPermissionDenied: { [weak self] in
                self?.promptForSystemAudioPermission()
            },
            onStartError: { [weak self] message in
                self?.errorMessage = message
            }
        )
    }

    /// Stop the meeting and finalize the transcription.
    @available(macOS 14.2, *)
    func stopMeeting() {
        guard isMeetingActive else { return }
        let context = contextService?.currentContext()
        meeting.stopSession(mode: activeMode, context: context)
    }

    /// Cancel the meeting without saving.
    @available(macOS 14.2, *)
    func cancelMeeting() {
        guard isMeetingActive else { return }
        meeting.cancelSession()
        meeting.markCancelled()
    }

    /// Pause audio capture without ending the Rust session. The user keeps
    /// looking at what they've captured so far; resume to continue.
    @available(macOS 14.2, *)
    func pauseMeeting() {
        guard isMeetingActive, !isMeetingPaused else { return }
        meeting.pauseSession()
        isMeetingPaused = true
    }

    @available(macOS 14.2, *)
    func resumeMeeting() {
        guard isMeetingActive, isMeetingPaused else { return }
        do {
            try meeting.resumeSession()
            isMeetingPaused = false
        } catch {
            errorMessage = "Failed to resume meeting: \(error.localizedDescription)"
        }
    }

    // MARK: - Transcription history

    func listTranscriptions(
        searchText: String? = nil,
        sourceFilter: String? = nil,
        limit: UInt32 = 50,
        offset: UInt32 = 0
    ) -> [StoredTranscription] {
        history.listTranscriptions(
            bridge: bridge,
            searchText: searchText,
            sourceFilter: sourceFilter,
            limit: limit,
            offset: offset
        )
    }

    func searchTranscriptions(query: String) -> [StoredTranscription] {
        history.searchTranscriptions(bridge: bridge, query: query)
    }

    func getTranscription(id: String) -> StoredTranscription? {
        history.getTranscription(bridge: bridge, id: id)
    }

    func updateTranscriptionTitle(id: String, title: String) {
        history.updateTranscriptionTitle(bridge: bridge, id: id, title: title)
    }

    func deleteTranscription(id: String) {
        history.deleteTranscription(bridge: bridge, id: id)
    }

    func deleteTranscriptions(ids: [String]) -> Int {
        history.deleteTranscriptions(bridge: bridge, ids: ids)
    }

    func getTranscriptionSegments(id: String) -> [TimestampedSegment] {
        history.getTranscriptionSegments(bridge: bridge, id: id)
    }

    // MARK: - Model management

    func loadModel(_ modelId: String) {
        model.loadModel(modelId, bridge: bridge)
    }

    // MARK: - Model downloading

    func listModels() -> [ParakattCore.ModelInfo] {
        model.listModels(bridge: bridge)
    }

    func startModelDownload(_ modelId: String) {
        model.startDownload(modelId, bridge: bridge)
    }

    func cancelModelDownload() {
        model.cancelDownload(bridge: bridge)
    }

    func deleteModel(_ modelId: String) {
        model.deleteModel(modelId, bridge: bridge)
    }

    // MARK: - Processing

    /// Single-shot transcription for short recordings (used when no incremental session was opened).
    private func processAudio(_ samples: [Float]) {
        isProcessing = true

        let sampleRate = recording.sampleRate
        let maxAmp = samples.map { abs($0) }.max() ?? 0
        NSLog("[Parakatt] Processing %d samples (%.1fs), maxAmp=%.4f, mode=%@, llm=%@",
              samples.count, Double(samples.count) / Double(sampleRate), maxAmp, activeMode, llmProvider.isEmpty ? "none" : llmProvider)

        guard let bridge else {
            isProcessing = false
            return
        }
        let context = contextService?.currentContext()
        let effectiveMode = settings.resolveEffectiveMode(for: context, bridge: bridge)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let signpostID = OSSignpostID(log: signpostLog)
            os_signpost(.begin, log: signpostLog, name: "Transcribe", signpostID: signpostID, "samples: %d", samples.count)
            defer { os_signpost(.end, log: signpostLog, name: "Transcribe", signpostID: signpostID) }

            do {
                let result = try bridge.transcribe(
                    audioSamples: samples,
                    sampleRate: sampleRate,
                    mode: effectiveMode,
                    context: context
                )

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isProcessing = false
                    self.lastTranscription = result.text
                    self.errorMessage = nil

                    if !result.text.isEmpty {
                        self.errorMessage = self.textOutput.insertIfEnabled(
                            text: result.text,
                            autoPaste: self.autoPaste,
                            inserter: self.textInsertionService
                        )
                        self.sendTranscriptionNotification(preview: result.text, source: "push_to_talk")
                        NSLog("[Parakatt] Result (%@, %.2fs): %@", self.activeMode, result.durationSecs, result.text)
                    } else {
                        NSLog("[Parakatt] Empty transcription (mode=%@, maxAmp=%.4f)", self.activeMode, maxAmp)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isProcessing = false
                    self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                    NSLog("[Parakatt] Transcription FAILED: %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Incremental push-to-talk processing

    /// Transition from throwaway streaming preview to incremental session-based processing.
    private func startIncrementalSession() {
        guard isRecording, let bridge else { return }

        let sessionId = UUID().uuidString

        do {
            try bridge.startSession(sessionId: sessionId)
        } catch {
            NSLog("[Parakatt] Failed to start PTT session: %@ — will use single-shot on stop",
                  error.localizedDescription)
            return  // PTT session stays nil → falls through to single-shot
        }

        recording.startPttSession(id: sessionId)

        // Keep streaming preview running — it will compose accumulated chunk text
        // with a live preview of the unprocessed buffer tail, keeping the overlay
        // updated between chunk dispatches.

        // Dispatch the first chunk immediately (~5s of audio).
        dispatchPttChunk()

        // Set up repeating timer that wakes every configured interval
        // and decides whether the audio buffer is in a state where it
        // should be flushed as a commit chunk. Policy lives in
        // dispatchPttChunk: dispatch when (a) buffer ≥ minimum chunk
        // duration AND (the speaker has been silent long enough to mark
        // a pause OR the buffer reached the maximum chunk duration).
        recording.startPttDispatchTimer(interval: recording.pttDispatchTickSecs) { [weak self] in
            self?.dispatchPttChunk()
        }

        NSLog("[Parakatt] Incremental session started (id: %@)", sessionId)
    }

    /// VAD-aware chunk dispatch policy.
    ///
    /// On every timer tick, evaluate
    /// whether the audio buffer is in a state where we should flush
    /// it to the commit pipeline:
    ///
    ///   * If the buffer holds less than the configured minimum audio,
    ///     do nothing — the model wastes work on too-short clips.
    ///   * Otherwise, dispatch when EITHER
    ///       - the speaker has been silent for at least
    ///         the configured number of consecutive audio
    ///         callbacks (~500 ms), giving us a natural sentence
    ///         boundary, OR
    ///       - the buffer has reached the configured hard
    ///         upper bound that prevents the user being stuck on a
    ///         non-stop monologue.
    ///
    /// Chunks become variable-length and naturally aligned to
    /// pauses, which is dramatically more responsive than the old
    /// fixed 30 s × 28 s timer.
    private func dispatchPttChunk() {
        guard let sessionId = recording.currentPttSessionId(), isRecording else { return }

        let sampleRate = recording.sampleRate
        let minSamples = Int(recording.pttMinChunkSecs * Double(sampleRate))
        let maxSamples = Int(recording.pttMaxChunkSecs * Double(sampleRate))
        let overlapSamples = Int(recording.overlapDurationSecs * Double(sampleRate))

        guard let chunk = recording.preparePttChunk(
            minSamples: minSamples,
            maxSamples: maxSamples,
            overlapSamples: overlapSamples,
            chunkIndex: recording.currentPttChunkIndex(),
            pauseSilenceCallbacks: recording.pttPauseSilenceCallbacks
        ) else { return }
        let chunkSamples = chunk.samples

        // The audio buffer just shrank — the buffered preview's
        // LA-2 is now operating on a shorter hypothesis than its
        // committed prefix, which would freeze the preview ("stuck
        // after ~2 sentences" bug). Reset the LA-2 state and the
        // gate watermark so the preview starts fresh on the new
        // (shorter) tail. The committed text we want the user to
        // see across chunk boundaries is the accumulated PTT text,
        // which is updated when the chunk processing returns.
        recording.resetPreviewWatermark()
        if let bpId = recording.currentBufferedPreviewSessionId() {
            try? bridge?.bufferedPreviewReset(sessionId: bpId)
        }

        let currentIndex = recording.takeNextPttChunkIndex()
        let context = contextService?.currentContext()
        let mode = activeMode

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let bridge = self.bridge else { return }

            self.recording.withPttChunkLock {
                do {
                    let result = try bridge.processChunk(
                        sessionId: sessionId,
                        audioSamples: chunkSamples,
                        sampleRate: sampleRate,
                        chunkIndex: currentIndex,
                        mode: mode,
                        context: context
                    )
                    // Pull the running accumulated text on demand instead of
                    // having Rust clone it on every chunk.
                    let acc = (try? bridge.getSessionText(sessionId: sessionId)) ?? ""
                    if let llmErr = result.llmError {
                        NSLog("[Parakatt] PTT chunk %d LLM degraded (raw text used): %@", currentIndex, llmErr)
                    }
                    DispatchQueue.main.async {
                        if self.isRecording || self.isProcessing {
                            let newAccumulated = acc.isEmpty ? nil : acc
                            self.recording.setPttAccumulatedText(newAccumulated)
                            // Immediately update live display to prevent flash/disappearance
                            // The streaming preview will append the tail on its next cycle
                            if let text = newAccumulated {
                                self.liveTranscription = text
                            }
                        }
                    }
                    NSLog("[Parakatt] PTT chunk %d: \"%@\"", currentIndex, result.text)
                } catch {
                    NSLog("[Parakatt] PTT chunk %d failed: %@", currentIndex, error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Streaming (throwaway preview for initial seconds)

    private func updateLiveTranscription() {
        guard isRecording, let bridge else { return }

        // If the cache-aware streaming preview is doing its thing
        // we don't need to also run the buffered preview — they
        // both publish to livePreviewCommitted/Tentative and one
        // will dominate. Skip to save CPU.
        if livePreview.isActive { return }

        guard recording.beginStreamTranscribing() else { return }

        // Snapshot the current buffer (unprocessed tail during incremental mode)
        let snapshot = recording.snapshotBuffer()

        guard recording.shouldRunBufferedPreview(
            snapshotCount: snapshot.count,
            minSamples: recording.minSamplesForStreaming,
            minNewSamples: recording.minNewSamplesForRestream
        ) else {
            recording.finishStreamTranscribing()
            return
        }

        // Limit snapshot to last 30 seconds to avoid OOM on very long recordings
        let sampleRate = recording.sampleRate
        let maxSamples = 30 * Int(sampleRate)
        let trimmed = snapshot.count > maxSamples
            ? Array(snapshot.suffix(maxSamples))
            : snapshot

        guard let bpSessionId = recording.ensureBufferedPreviewSession(bridge: bridge) else {
            recording.finishStreamTranscribing()
            return
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            defer {
                DispatchQueue.main.async {
                    self.recording.finishStreamTranscribing()
                }
            }

            do {
                let result = try bridge.bufferedPreviewUpdate(
                    sessionId: bpSessionId,
                    audioSamples: trimmed,
                    sampleRate: sampleRate
                )
                DispatchQueue.main.async {
                    if self.isRecording {
                        self.recording.applyBufferedPreview(
                            committedText: result.committedText,
                            tentativeText: result.tentativeText
                        )
                    }
                }
            } catch {
                // Silently ignore streaming errors
            }
        }
    }

    // MARK: - Notifications

    private func sendTranscriptionNotification(preview: String, source: String) {
        notifications.sendTranscriptionReady(environment: environment, preview: preview, source: source)
    }

    // MARK: - Audio buffer

    private func appendAudioSamples(_ samples: [Float]) {
        let result = recording.appendAudioSamples(samples, isRecording: isRecording, livePreviewActive: livePreview.isActive)

        // Feed the cache-aware streaming preview in parallel. The service does
        // its own backpressure (drops if a feed is already in flight) so we can
        // call it on every audio callback without queue pile-up.
        if result.shouldFeedLivePreview {
            livePreview.enqueue(samples)
        }

        // Warn once when push-to-talk exceeds 5 minutes.
        if let durationMins = result.longRecordingWarningMinutes {
            NSLog("[Parakatt] WARNING: Push-to-talk recording exceeds %.0f minutes — consider using meeting mode for long recordings", durationMins)
        }

        if result.speechResumed {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Bypass the "buffer hasn't grown enough" gate by
                // resetting the watermark; we want this pass to run
                // even if only ~one frame of new audio has arrived.
                self.recording.resetPreviewWatermark()
                self.updateLiveTranscription()
            }
        }

        if let callbackNumber = result.callbackNumberToLog {
            NSLog("[Parakatt] Audio callback #%d, buffer: %d samples (%.1fs)", callbackNumber, result.totalSamples, Double(result.totalSamples) / Double(recording.sampleRate))
        }
    }

    // MARK: - Permission helpers

    private func promptForSystemAudioPermission() {
        permissions.promptForSystemAudioPermission(environment: environment)
    }
}

/// UI-facing summary of meeting-time audio capture health.
/// Driven by MeetingSessionService.onChunkHealth and the system-audio tap's
/// own onHealth signal. Distinguishes "only your voice is being captured"
/// from "everything is fine" so the user doesn't have to infer it from a
/// missing transcript at the end.
enum MeetingAudioStatus: Equatable {
    /// No meeting active, or no signal observed yet.
    case unknown
    /// Both sources delivering signal above the silence threshold.
    case healthy
    /// Mic has signal but system audio has been silent or empty for a while.
    /// `since` marks when we first noticed; use it to decide whether to
    /// surface a warning to the user.
    case systemSilent(since: Date)
    /// Both mic and system are effectively silent. Usually transient.
    case bothSilent
    /// The system-audio tap reports empty buffers (e.g. wrong output device
    /// is the aggregate's main, or no audio is playing).
    case systemEmpty
    /// User hasn't granted Screen & System Audio Recording.
    case permissionDenied
    /// Any other capture failure.
    case error(String)
}
