import AppKit
import Combine
import HotKey
import os.log
import ParakattCore

private let logger = Logger(subsystem: "com.parakatt.app", category: "engine")

/// Observable application state shared across the UI.
///
/// Coordinates recording, transcription, and text insertion.
class AppState: ObservableObject {
    // MARK: - Published state

    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var lastTranscription: String?
    @Published var liveTranscription: String?
    @Published var activeMode = "dictation"
    @Published var isModelLoaded = false
    @Published var activeModelId: String?
    @Published var errorMessage: String?
    @Published var needsModelDownload = false
    @Published var isDownloading = false
    @Published var downloadProgress: ParakattCore.DownloadProgress?
    @Published var currentAudioLevel: Float = 0

    // Meeting state
    @Published var isMeetingActive = false
    @Published var meetingElapsedTime: TimeInterval = 0
    @Published var meetingTranscription: String?
    @Published var meetingLatestChunk: String?

    // Audio source selection (meeting mode)
    @Published var selectedAudioSourcePID: pid_t?
    @Published var selectedAudioSourceName: String?

    // MARK: - Services

    /// Set by AppDelegate after init; used for hotkey reconfiguration.
    var hotkeyService: HotkeyService?
    private var audioCaptureService: AudioCaptureService?
    private var textInsertionService: TextInsertionService?
    private var contextService: ContextService?

    @available(macOS 14.2, *)
    private var meetingSession: MeetingSessionService? {
        get { _meetingSession as? MeetingSessionService }
        set { _meetingSession = newValue }
    }
    private var _meetingSession: AnyObject?
    private var meetingElapsedTimer: Timer?

    // MARK: - Audio buffer

    private var audioBuffer: [Float] = []
    private let audioBufferLock = NSLock()

    // MARK: - Incremental push-to-talk session

    /// Session ID for incremental processing (nil = short recording, single-shot).
    private var pttSessionId: String?
    private var pttChunkIndex: UInt32 = 0
    private var pttChunkTimer: Timer?
    private let pttChunkLock = NSLock()  // serializes chunk processing
    /// Accumulated text from processed chunks (used to compose live display).
    private var pttAccumulatedText: String?

    /// Seconds before transitioning from single-shot preview to incremental chunking.
    private let firstChunkDelaySecs: TimeInterval = 5.0
    /// Chunk dispatch interval after the first chunk (30s chunk - 2s overlap).
    private let pttChunkIntervalSecs: TimeInterval = 28.0

    // MARK: - Engine bridge

    private var bridge: CoreBridge?
    private var engineReady = false

    // MARK: - Lifecycle

    func initializeEngine() {
        // Set up services
        textInsertionService = TextInsertionService()
        contextService = ContextService()

        // Create audio capture once — reused across all recording sessions
        let capture = AudioCaptureService()
        capture.onAudioSamples = { [weak self] samples in
            self?.appendAudioSamples(samples)
        }
        audioCaptureService = capture

        NSLog("[Parakatt] Initializing engine...")

        // Create the engine (lightweight — no model loaded yet)
        do {
            bridge = try CoreBridge(
                modelsDir: modelsDirectory().path,
                configDir: configDirectory().path,
                activeMode: activeMode
            )
            engineReady = true
            NSLog("[Parakatt] Engine created")

            // Load preferred audio source from config
            if let bundleId = bridge?.getPreferredAudioSource() {
                if let pid = AudioSourceService.pidForBundleId(bundleId) {
                    selectedAudioSourcePID = pid
                    let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                        .first?.localizedName ?? bundleId
                    selectedAudioSourceName = name
                    NSLog("[Parakatt] Restored preferred audio source: %@ (pid %d)", name, pid)
                } else {
                    NSLog("[Parakatt] Preferred audio source %@ not running", bundleId)
                }
            }
        } catch {
            errorMessage = "Failed to initialize engine: \(error.localizedDescription)"
            NSLog("[Parakatt] Engine init failed: \(error)")
            return
        }

        // Check if any model is downloaded; if not, prompt user to download
        let models = bridge?.listModels() ?? []
        let downloadedModel = models.first(where: { $0.downloaded })

        if let model = downloadedModel {
            // Load the downloaded model on a background thread (Metal/GPU init is heavy)
            let modelId = model.id
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self, let bridge = self.bridge else { return }

                NSLog("[Parakatt] Loading model '%@' in background...", modelId)
                do {
                    try bridge.loadModel(modelId)
                    DispatchQueue.main.async {
                        self.isModelLoaded = true
                        self.activeModelId = modelId
                        NSLog("[Parakatt] Model loaded — ready to transcribe")
                    }
                } catch {
                    DispatchQueue.main.async {
                        NSLog("[Parakatt] Model load failed: \(error) — transcription won't work until a model is loaded")
                    }
                }
            }
        } else {
            NSLog("[Parakatt] No model downloaded — user needs to download one")
            needsModelDownload = true
        }
    }

    func shutdown() {
        stopRecording()
        if let sessionId = pttSessionId {
            bridge?.cancelSession(sessionId: sessionId)
            pttSessionId = nil
        }
        if #available(macOS 14.2, *) {
            cancelMeeting()
        }
        bridge = nil
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else {
            NSLog("[Parakatt] startRecording called but already recording — ignoring")
            return
        }
        guard engineReady else {
            NSLog("[Parakatt] Cannot record: engine not ready (modelLoaded=%d)", isModelLoaded ? 1 : 0)
            return
        }

        sampleCount = 0
        longRecordingWarned = false
        pttSessionId = nil
        pttChunkIndex = 0
        pttChunkTimer?.invalidate()
        pttChunkTimer = nil
        pttAccumulatedText = nil

        audioBufferLock.lock()
        audioBuffer.removeAll()
        audioBufferLock.unlock()

        do {
            try audioCaptureService?.startCapture()
            isRecording = true
            currentAudioLevel = 0
            liveTranscription = nil
            errorMessage = nil

            // Start throwaway 2s preview for immediate feedback.
            startStreamingUpdates()

            // After 5s, transition to incremental session-based processing.
            pttChunkTimer = Timer.scheduledTimer(
                withTimeInterval: firstChunkDelaySecs,
                repeats: false
            ) { [weak self] _ in
                self?.startIncrementalSession()
            }

            NSLog("[Parakatt] Recording STARTED (modelLoaded=%d, incremental after %.0fs)",
                  isModelLoaded ? 1 : 0, firstChunkDelaySecs)
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            NSLog("[Parakatt] Recording FAILED: %@", error.localizedDescription)
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        pttChunkTimer?.invalidate()
        pttChunkTimer = nil
        stopStreamingUpdates()
        audioCaptureService?.stopCapture()
        isRecording = false
        currentAudioLevel = 0

        if let sessionId = pttSessionId {
            // Path B: incremental session was active — only process the tail.
            isProcessing = true
            // Keep liveTranscription visible while processing the tail.
            NSLog("[Parakatt] Recording stopped (incremental session, processing tail)")

            audioBufferLock.lock()
            let remainingSamples = audioBuffer
            audioBuffer.removeAll()
            audioBufferLock.unlock()

            let context = contextService?.currentContext()
            let mode = activeMode
            let currentIndex = pttChunkIndex

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self, let bridge = self.bridge else {
                    DispatchQueue.main.async { self?.isProcessing = false }
                    return
                }

                // Wait for any in-flight chunk to complete.
                self.pttChunkLock.lock()

                // Process remaining tail (if >= 1s of audio).
                if remainingSamples.count >= Int(self.sttSampleRate) {
                    do {
                        let result = try bridge.processChunk(
                            sessionId: sessionId,
                            audioSamples: remainingSamples,
                            sampleRate: self.sttSampleRate,
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
                          Double(remainingSamples.count) / Double(self.sttSampleRate))
                }

                self.pttChunkLock.unlock()

                // Finish the session.
                do {
                    let result = try bridge.finishSession(
                        sessionId: sessionId,
                        mode: mode,
                        context: context
                    )
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.liveTranscription = nil
                        self.pttAccumulatedText = nil
                        self.lastTranscription = result.text
                        self.pttSessionId = nil
                        self.errorMessage = nil

                        if !result.text.isEmpty {
                            self.textInsertionService?.insertText(result.text)
                            NSLog("[Parakatt] PTT session result (%@, %.2fs): %@",
                                  mode, result.durationSecs, result.text)
                        }
                    }
                } catch {
                    bridge.cancelSession(sessionId: sessionId)
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.liveTranscription = nil
                        self.pttAccumulatedText = nil
                        self.pttSessionId = nil
                        self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                        NSLog("[Parakatt] PTT session finish FAILED: %@", error.localizedDescription)
                    }
                }
            }
        } else {
            // Path A: short recording, no session — single-shot processing.
            liveTranscription = nil
            NSLog("[Parakatt] Recording stopped (short, single-shot)")

            audioBufferLock.lock()
            let samples = audioBuffer
            audioBuffer.removeAll()
            audioBufferLock.unlock()

            guard !samples.isEmpty else {
                NSLog("[Parakatt] stopRecording: NO AUDIO IN BUFFER")
                errorMessage = "No audio captured"
                return
            }

            processAudio(samples)
        }
    }

    // MARK: - Diagnostics

    /// Record 3 seconds and log audio stats + transcription result.
    func runDiagnostic() {
        NSLog("[Parakatt] === DIAGNOSTIC START ===")

        let devices = AudioCaptureService.listInputDevices()
        for dev in devices {
            NSLog("[Parakatt] Device: %@ (uid: %@, default: %d)", dev.name, dev.uid, dev.isDefault ? 1 : 0)
        }

        NSLog("[Parakatt] Starting test recording (3 seconds)...")
        startRecording()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }

            self.audioBufferLock.lock()
            let samples = self.audioBuffer
            self.audioBufferLock.unlock()

            let maxAmp = samples.map { abs($0) }.max() ?? 0
            let rms = samples.isEmpty ? 0 : sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))

            NSLog("[Parakatt] DIAGNOSTIC: %d samples (%.1fs), max=%.6f, rms=%.6f",
                  samples.count, Double(samples.count) / 16000.0, maxAmp, rms)

            if maxAmp > 0.001 {
                NSLog("[Parakatt] DIAGNOSTIC: ✅ Audio has signal — stopping and transcribing")
            } else {
                NSLog("[Parakatt] DIAGNOSTIC: ❌ SILENCE — mic not capturing audio")
                NSLog("[Parakatt] DIAGNOSTIC: Check System Settings > Privacy > Microphone")
            }

            self.stopRecording()
            NSLog("[Parakatt] === DIAGNOSTIC END ===")
        }
    }

    /// Test system audio capture for 3 seconds and log results.
    @available(macOS 14.2, *)
    func runSystemAudioDiagnostic() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        NSLog("[Parakatt] === SYSTEM AUDIO DIAGNOSTIC START (macOS %d.%d.%d) ===",
              osVersion.majorVersion, osVersion.minorVersion, osVersion.patchVersion)

        let testCapture = SystemAudioCaptureService()
        var collectedSamples: [Float] = []
        let sampleLock = NSLock()

        testCapture.onAudioSamples = { samples in
            sampleLock.lock()
            collectedSamples.append(contentsOf: samples)
            sampleLock.unlock()
        }

        do {
            try testCapture.startCapture()
            NSLog("[Parakatt] SYSDIAG: Capturing all system audio for 3 seconds...")
        } catch {
            NSLog("[Parakatt] SYSDIAG: ❌ Failed to start capture: %@", error.localizedDescription)
            NSLog("[Parakatt] === SYSTEM AUDIO DIAGNOSTIC END ===")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            testCapture.stopCapture()

            sampleLock.lock()
            let samples = collectedSamples
            sampleLock.unlock()

            let maxAmp = samples.map { abs($0) }.max() ?? 0
            let rms = samples.isEmpty ? 0 : sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))

            NSLog("[Parakatt] SYSDIAG: %d samples (%.1fs), max=%.6f, rms=%.6f",
                  samples.count, Double(samples.count) / 16000.0, maxAmp, rms)

            if samples.isEmpty {
                NSLog("[Parakatt] SYSDIAG: ❌ NO SAMPLES — system audio callback never fired")
                NSLog("[Parakatt] SYSDIAG: Check System Settings > Privacy & Security > Screen & System Audio Recording")
            } else if maxAmp > 0.001 {
                NSLog("[Parakatt] SYSDIAG: ✅ System audio has signal")
            } else {
                NSLog("[Parakatt] SYSDIAG: ⚠️ Samples received but SILENT (max=%.6f) — is audio playing from another app?", maxAmp)
            }

            NSLog("[Parakatt] === SYSTEM AUDIO DIAGNOSTIC END ===")
        }
    }

    // MARK: - LLM

    @Published var llmProvider: String = ""
    @Published var llmBaseUrl: String = "http://localhost:11434"
    @Published var llmModel: String = "llama3.2"
    @Published var llmApiKey: String = ""

    func configureLlm() {
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

    func fetchLlmModels() -> [String] {
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

    // MARK: - Dictionary

    func getDictionaryRules() -> [ParakattCore.ReplacementRule] {
        bridge?.getDictionaryRules() ?? []
    }

    func setDictionaryRules(_ rules: [ParakattCore.ReplacementRule]) {
        do {
            try bridge?.setDictionaryRules(rules)
            NSLog("[Parakatt] Dictionary updated: %d rules", rules.count)
        } catch {
            NSLog("[Parakatt] Failed to set dictionary rules: %@", error.localizedDescription)
        }
    }

    // MARK: - Input device

    func setInputDevice(uid: String?) {
        audioCaptureService?.setInputDevice(uid: uid)
        NSLog("[Parakatt] Input device set to: %@", uid ?? "system default")
    }

    // MARK: - Hotkey configuration

    /// Load hotkey config from the Rust engine. Returns parsed key/modifiers/mode.
    func loadHotkeyConfig() -> (key: Key, modifiers: NSEvent.ModifierFlags, mode: String) {
        guard let bridge else {
            return (.space, [.option], "hold")
        }
        let config = bridge.getHotkeyConfig()
        let key = HotkeyService.keyFromString(config.key) ?? .space
        let modifiers = HotkeyService.modifiersFromStrings(config.modifiers)
        let mode = config.mode
        return (key, modifiers.isEmpty ? [.option] : modifiers, mode)
    }

    /// Save hotkey config and reconfigure the service.
    func setHotkey(key: Key, modifiers: NSEvent.ModifierFlags, mode: String) {
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

    // MARK: - Audio source preference

    /// Persist the preferred audio source bundle ID.
    func setPreferredAudioSource(bundleId: String?) {
        do {
            try bridge?.setPreferredAudioSource(bundleId)
        } catch {
            NSLog("[Parakatt] Failed to save audio source preference: %@", error.localizedDescription)
        }
    }

    // MARK: - Meeting transcription

    /// Start a meeting transcription session.
    @available(macOS 14.2, *)
    func startMeeting() {
        guard !isMeetingActive else { return }
        guard engineReady, let bridge else {
            errorMessage = "Engine not ready"
            return
        }

        let session = MeetingSessionService(bridge: bridge)

        session.onChunkTranscribed = { [weak self] newText, accumulated, _ in
            self?.meetingLatestChunk = newText
            self?.meetingTranscription = accumulated
        }

        session.onSessionFinished = { [weak self] result in
            self?.isMeetingActive = false
            self?.meetingElapsedTimer?.invalidate()
            self?.meetingElapsedTimer = nil
            self?.meetingTranscription = result.text
            self?.meetingLatestChunk = nil
            NSLog("[Parakatt] Meeting finished: %.0fs, %d chars", result.durationSecs, result.text.count)
        }

        session.onError = { [weak self] message in
            self?.isMeetingActive = false
            self?.meetingElapsedTimer?.invalidate()
            self?.meetingElapsedTimer = nil
            self?.errorMessage = message
        }

        meetingSession = session
        isMeetingActive = true
        meetingTranscription = nil
        meetingLatestChunk = nil
        meetingElapsedTime = 0

        // Start elapsed time updates.
        meetingElapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if #available(macOS 14.2, *) {
                self.meetingElapsedTime = self.meetingSession?.elapsedTime ?? 0
            }
        }

        do {
            let context = contextService?.currentContext()
            try session.start(processID: selectedAudioSourcePID, mode: activeMode, context: context)
            if let name = selectedAudioSourceName {
                NSLog("[Parakatt] Meeting capturing audio from: %@", name)
            }
        } catch {
            // If a specific app was selected but its process is gone, fall back to all system audio.
            if selectedAudioSourcePID != nil,
               let audioErr = error as? SystemAudioCaptureError,
               case .processNotFound = audioErr {
                NSLog("[Parakatt] Selected app not found (pid %d), falling back to all system audio",
                      selectedAudioSourcePID ?? 0)
                do {
                    let context = contextService?.currentContext()
                    try session.start(processID: nil, mode: activeMode, context: context)
                    return
                } catch {
                    // Fall through to error handling below
                }
            }

            isMeetingActive = false
            meetingElapsedTimer?.invalidate()
            meetingElapsedTimer = nil

            if let audioErr = error as? SystemAudioCaptureError, case .permissionDenied = audioErr {
                promptForSystemAudioPermission()
            } else {
                errorMessage = "Failed to start meeting: \(error.localizedDescription)"
            }
        }
    }

    /// Stop the meeting and finalize the transcription.
    @available(macOS 14.2, *)
    func stopMeeting() {
        guard isMeetingActive else { return }
        let context = contextService?.currentContext()
        meetingSession?.stop(mode: activeMode, context: context)
    }

    /// Cancel the meeting without saving.
    @available(macOS 14.2, *)
    func cancelMeeting() {
        guard isMeetingActive else { return }
        meetingSession?.cancel()
        isMeetingActive = false
        meetingElapsedTimer?.invalidate()
        meetingElapsedTimer = nil
        meetingTranscription = nil
        meetingLatestChunk = nil
    }

    // MARK: - Transcription history

    func listTranscriptions(
        searchText: String? = nil,
        sourceFilter: String? = nil,
        limit: UInt32 = 50,
        offset: UInt32 = 0
    ) -> [StoredTranscription] {
        let query = TranscriptionQuery(
            searchText: searchText,
            sourceFilter: sourceFilter,
            limit: limit,
            offset: offset
        )
        return (try? bridge?.listTranscriptions(query: query)) ?? []
    }

    func searchTranscriptions(query: String) -> [StoredTranscription] {
        (try? bridge?.searchTranscriptions(searchText: query)) ?? []
    }

    func getTranscription(id: String) -> StoredTranscription? {
        try? bridge?.getTranscription(id: id)
    }

    func updateTranscriptionTitle(id: String, title: String) {
        try? bridge?.updateTranscriptionTitle(id: id, title: title)
    }

    func deleteTranscription(id: String) {
        try? bridge?.deleteTranscription(id: id)
    }

    func deleteTranscriptions(ids: [String]) -> Int {
        Int((try? bridge?.deleteTranscriptions(ids: ids)) ?? 0)
    }

    func getTranscriptionSegments(id: String) -> [TimestampedSegment] {
        (try? bridge?.getTranscriptionSegments(id: id)) ?? []
    }

    // MARK: - Model management

    func loadModel(_ modelId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.bridge?.loadModel(modelId)
                DispatchQueue.main.async {
                    self.isModelLoaded = true
                    self.activeModelId = modelId
                    self.errorMessage = nil
                    NSLog("[Parakatt] Loaded model: \(modelId)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load model: \(error.localizedDescription)"
                    NSLog("[Parakatt] Model load failed: \(error)")
                }
            }
        }
    }

    // MARK: - Model downloading

    private var downloadPollTimer: Timer?

    func listModels() -> [ParakattCore.ModelInfo] {
        bridge?.listModels() ?? []
    }

    func startModelDownload(_ modelId: String) {
        do {
            try bridge?.startDownload(modelId)
            isDownloading = true
            startDownloadPolling()
            NSLog("[Parakatt] Started download: %@", modelId)
        } catch {
            errorMessage = "Failed to start download: \(error.localizedDescription)"
            NSLog("[Parakatt] Download start failed: %@", error.localizedDescription)
        }
    }

    func cancelModelDownload() {
        bridge?.cancelDownload()
        NSLog("[Parakatt] Download cancelled")
    }

    func deleteModel(_ modelId: String) {
        do {
            try bridge?.deleteModel(modelId)
            // If the deleted model was loaded, reset state
            if activeModelId == modelId {
                isModelLoaded = false
                activeModelId = nil
                needsModelDownload = listModels().first(where: { $0.downloaded }) == nil
            }
            NSLog("[Parakatt] Deleted model: %@", modelId)
        } catch {
            errorMessage = "Failed to delete model: \(error.localizedDescription)"
            NSLog("[Parakatt] Delete model failed: %@", error.localizedDescription)
        }
    }

    private func startDownloadPolling() {
        downloadPollTimer?.invalidate()
        downloadPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollDownloadProgress()
        }
    }

    private func stopDownloadPolling() {
        downloadPollTimer?.invalidate()
        downloadPollTimer = nil
    }

    private func pollDownloadProgress() {
        guard let bridge else { return }

        let progress = bridge.getDownloadProgress()
        downloadProgress = progress

        switch progress.state {
        case .completed:
            stopDownloadPolling()
            isDownloading = false
            needsModelDownload = false
            NSLog("[Parakatt] Download completed: %@", progress.modelId)
            // Auto-load the just-downloaded model
            loadModel(progress.modelId)

        case .failed(let message):
            stopDownloadPolling()
            isDownloading = false
            errorMessage = "Download failed: \(message)"
            NSLog("[Parakatt] Download failed: %@", message)

        case .cancelled:
            stopDownloadPolling()
            isDownloading = false
            NSLog("[Parakatt] Download cancelled")

        case .idle:
            stopDownloadPolling()
            isDownloading = false

        case .downloading:
            break // keep polling
        }
    }

    // MARK: - Processing

    /// Maximum duration (seconds) for single-shot transcription. Longer recordings are chunked.
    private let chunkDurationSecs: Double = 30.0
    /// Overlap between consecutive chunks to avoid cutting words at boundaries.
    private let overlapDurationSecs: Double = 2.0
    private let sttSampleRate: UInt32 = 16_000

    /// Single-shot transcription for short recordings (used when no incremental session was opened).
    private func processAudio(_ samples: [Float]) {
        isProcessing = true

        let maxAmp = samples.map { abs($0) }.max() ?? 0
        NSLog("[Parakatt] Processing %d samples (%.1fs), maxAmp=%.4f, mode=%@, llm=%@",
              samples.count, Double(samples.count) / 16000.0, maxAmp, activeMode, llmProvider.isEmpty ? "none" : llmProvider)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let bridge = self.bridge else {
                DispatchQueue.main.async { self?.isProcessing = false }
                return
            }

            let context = self.contextService?.currentContext()

            do {
                let result = try bridge.transcribe(
                    audioSamples: samples,
                    sampleRate: 16000,
                    mode: self.activeMode,
                    context: context
                )

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastTranscription = result.text
                    self.errorMessage = nil

                    if !result.text.isEmpty {
                        self.textInsertionService?.insertText(result.text)
                        NSLog("[Parakatt] Result (%@, %.2fs): %@", self.activeMode, result.durationSecs, result.text)
                    } else {
                        NSLog("[Parakatt] Empty transcription (mode=%@, maxAmp=%.4f)", self.activeMode, maxAmp)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                    NSLog("[Parakatt] Transcription FAILED: %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Incremental push-to-talk processing

    /// Transition from throwaway streaming preview to incremental session-based
    /// processing. Called after `firstChunkDelaySecs` of recording.
    private func startIncrementalSession() {
        guard isRecording, let bridge else { return }

        let sessionId = UUID().uuidString

        do {
            try bridge.startSession(sessionId: sessionId)
        } catch {
            NSLog("[Parakatt] Failed to start PTT session: %@ — will use single-shot on stop",
                  error.localizedDescription)
            return  // pttSessionId stays nil → falls through to single-shot
        }

        pttSessionId = sessionId

        // Keep streaming preview running — it will compose accumulated chunk text
        // with a live preview of the unprocessed buffer tail, keeping the overlay
        // updated between chunk dispatches.

        // Dispatch the first chunk immediately (~5s of audio).
        dispatchPttChunk()

        // Set up repeating timer for subsequent chunks.
        pttChunkTimer = Timer.scheduledTimer(
            withTimeInterval: pttChunkIntervalSecs,
            repeats: true
        ) { [weak self] _ in
            self?.dispatchPttChunk()
        }

        NSLog("[Parakatt] Incremental session started (id: %@)", sessionId)
    }

    /// Dispatch the next chunk from the audio buffer for incremental processing.
    /// Adapted from MeetingSessionService.dispatchChunk().
    private func dispatchPttChunk() {
        guard let sessionId = pttSessionId, isRecording else { return }

        let samplesPerChunk = Int(chunkDurationSecs * Double(sttSampleRate))
        let overlapSamples = Int(overlapDurationSecs * Double(sttSampleRate))

        audioBufferLock.lock()
        guard audioBuffer.count >= Int(sttSampleRate) else {
            // Less than 1 second of audio — skip this dispatch.
            audioBufferLock.unlock()
            return
        }
        let chunkSamples = Array(audioBuffer.prefix(samplesPerChunk))
        let consumed = max(0, chunkSamples.count - overlapSamples)
        if consumed > 0 {
            audioBuffer.removeFirst(consumed)
        }
        audioBufferLock.unlock()

        let currentIndex = pttChunkIndex
        pttChunkIndex += 1
        let context = contextService?.currentContext()
        let mode = activeMode

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let bridge = self.bridge else { return }

            self.pttChunkLock.lock()
            defer { self.pttChunkLock.unlock() }

            do {
                let result = try bridge.processChunk(
                    sessionId: sessionId,
                    audioSamples: chunkSamples,
                    sampleRate: self.sttSampleRate,
                    chunkIndex: currentIndex,
                    mode: mode,
                    context: context
                )
                DispatchQueue.main.async {
                    if self.isRecording || self.isProcessing {
                        // Store accumulated text; streaming preview composes the display.
                        self.pttAccumulatedText = result.accumulatedText.isEmpty
                            ? nil : result.accumulatedText
                    }
                }
                NSLog("[Parakatt] PTT chunk %d: \"%@\"", currentIndex, result.text)
            } catch {
                NSLog("[Parakatt] PTT chunk %d failed: %@", currentIndex, error.localizedDescription)
            }
        }
    }

    // MARK: - Streaming (throwaway preview for initial seconds)

    private var streamingTimer: Timer?
    /// Interval between live transcription updates while recording.
    private let streamingInterval: TimeInterval = 2.0
    /// Minimum samples needed before first live transcription (1s at 16kHz).
    private let minSamplesForStreaming = 16000

    private func startStreamingUpdates() {
        streamingTimer?.invalidate()
        streamingTimer = Timer.scheduledTimer(withTimeInterval: streamingInterval, repeats: true) { [weak self] _ in
            self?.updateLiveTranscription()
        }
    }

    private func stopStreamingUpdates() {
        streamingTimer?.invalidate()
        streamingTimer = nil
    }

    private var isStreamTranscribing = false

    private func updateLiveTranscription() {
        guard isRecording, let bridge, !isStreamTranscribing else { return }

        // Snapshot the current buffer (unprocessed tail during incremental mode)
        audioBufferLock.lock()
        let snapshot = audioBuffer
        audioBufferLock.unlock()

        guard snapshot.count >= minSamplesForStreaming else { return }

        // Limit snapshot to last 30 seconds to avoid OOM on very long recordings
        let maxSamples = 30 * 16000
        let trimmed = snapshot.count > maxSamples
            ? Array(snapshot.suffix(maxSamples))
            : snapshot

        // Capture accumulated text from chunks already processed
        let accumulatedPrefix = pttAccumulatedText

        isStreamTranscribing = true

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            defer { self.isStreamTranscribing = false }

            do {
                let result = try bridge.transcribe(
                    audioSamples: trimmed,
                    sampleRate: 16000,
                    mode: "dictation",
                    context: nil
                )
                DispatchQueue.main.async {
                    if self.isRecording {
                        if let prefix = accumulatedPrefix, !prefix.isEmpty {
                            // Compose: accumulated chunk text + streaming tail preview
                            let tail = result.text.isEmpty ? "" : " " + result.text
                            self.liveTranscription = prefix + tail
                        } else {
                            self.liveTranscription = result.text.isEmpty ? nil : result.text
                        }
                    }
                }
            } catch {
                // Silently ignore streaming errors
            }
        }
    }

    // MARK: - Audio buffer

    private var sampleCount = 0

    /// Threshold for warning about long push-to-talk recordings (5 minutes).
    private let longRecordingWarningSamples = 5 * 60 * 16000
    private var longRecordingWarned = false

    private func appendAudioSamples(_ samples: [Float]) {
        audioBufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        let total = audioBuffer.count
        audioBufferLock.unlock()

        // Warn once when push-to-talk exceeds 5 minutes.
        if total > longRecordingWarningSamples && !longRecordingWarned {
            longRecordingWarned = true
            let durationMins = Double(total) / 16000.0 / 60.0
            NSLog("[Parakatt] WARNING: Push-to-talk recording exceeds %.0f minutes — consider using meeting mode for long recordings", durationMins)
        }

        // Compute RMS for audio level visualization
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(max(samples.count, 1)))
        // Normalize: typical speech RMS ~0.01-0.1, scale up for display
        let normalized = min(rms * 10, 1.0)
        let smoothed = 0.3 * currentAudioLevel + 0.7 * normalized
        DispatchQueue.main.async {
            self.currentAudioLevel = smoothed
        }

        sampleCount += 1
        if sampleCount % 50 == 1 {
            NSLog("[Parakatt] Audio callback #%d, buffer: %d samples (%.1fs)", sampleCount, total, Double(total) / 16000.0)
        }
    }

    // MARK: - Permission helpers

    private func promptForSystemAudioPermission() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "System Audio Recording Permission Required"
            alert.informativeText = "Parakatt needs permission to capture system audio for meeting transcription.\n\nClick \"Open System Settings\" and enable Parakatt under Screen & System Audio Recording, then try starting the meeting again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()

            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - Directories

    private func modelsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Parakatt/models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func configDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Parakatt/config")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
