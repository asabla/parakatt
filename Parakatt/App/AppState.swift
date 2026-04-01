import AppKit
import Combine
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

    // MARK: - Services

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
        audioBufferLock.lock()
        audioBuffer.removeAll()
        audioBufferLock.unlock()

        do {
            try audioCaptureService?.startCapture()
            isRecording = true
            currentAudioLevel = 0
            liveTranscription = nil
            errorMessage = nil
            startStreamingUpdates()
            NSLog("[Parakatt] Recording STARTED (modelLoaded=%d, streaming=%.0fs)", isModelLoaded ? 1 : 0, streamingInterval)
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            NSLog("[Parakatt] Recording FAILED: %@", error.localizedDescription)
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        stopStreamingUpdates()
        audioCaptureService?.stopCapture()
        isRecording = false
        currentAudioLevel = 0
        liveTranscription = nil
        NSLog("[Parakatt] Recording stopped")

        // Get the captured audio
        audioBufferLock.lock()
        let samples = audioBuffer
        audioBuffer.removeAll()
        audioBufferLock.unlock()

        guard !samples.isEmpty else {
            NSLog("[Parakatt] stopRecording: NO AUDIO IN BUFFER")
            errorMessage = "No audio captured"
            return
        }

        let durationSecs = Double(samples.count) / 16000.0
        NSLog("[Parakatt] Captured \(samples.count) samples (\(String(format: "%.1f", durationSecs))s)")

        processAudio(samples)
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

    func setInputDevice(uid: String) {
        audioCaptureService?.setInputDevice(uid: uid)
        NSLog("[Parakatt] Input device set to: %@", uid)
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
            try session.start(mode: activeMode, context: context)
        } catch {
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

    private func processAudio(_ samples: [Float]) {
        let durationSecs = Double(samples.count) / Double(sttSampleRate)
        if durationSecs > chunkDurationSecs {
            processAudioChunked(samples)
            return
        }

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

    /// Process long recordings by splitting into overlapping chunks and using
    /// the session-based transcription pipeline (same as meetings).
    private func processAudioChunked(_ samples: [Float]) {
        isProcessing = true

        let chunkSize = Int(chunkDurationSecs * Double(sttSampleRate))
        let overlapSize = Int(overlapDurationSecs * Double(sttSampleRate))
        let stride = chunkSize - overlapSize
        let totalChunks = max(1, (samples.count - overlapSize + stride - 1) / stride)

        NSLog("[Parakatt] Chunked processing: %d samples (%.1fs) → %d chunks of %.0fs with %.0fs overlap, mode=%@",
              samples.count, Double(samples.count) / Double(sttSampleRate),
              totalChunks, chunkDurationSecs, overlapDurationSecs, activeMode)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let bridge = self.bridge else {
                DispatchQueue.main.async { self?.isProcessing = false }
                return
            }

            let sessionId = UUID().uuidString
            let context = self.contextService?.currentContext()

            do {
                try bridge.startSession(sessionId: sessionId)

                var offset = 0
                var chunkIndex: UInt32 = 0
                while offset < samples.count {
                    let end = min(offset + chunkSize, samples.count)
                    let chunk = Array(samples[offset..<end])

                    let result = try bridge.processChunk(
                        sessionId: sessionId,
                        audioSamples: chunk,
                        sampleRate: self.sttSampleRate,
                        chunkIndex: chunkIndex,
                        mode: self.activeMode,
                        context: context
                    )
                    NSLog("[Parakatt] Chunk %d/%d: \"%@\"", chunkIndex + 1, totalChunks, result.text)

                    offset += stride
                    chunkIndex += 1
                }

                let result = try bridge.finishSession(
                    sessionId: sessionId,
                    mode: self.activeMode,
                    context: context
                )

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastTranscription = result.text
                    self.errorMessage = nil

                    if !result.text.isEmpty {
                        self.textInsertionService?.insertText(result.text)
                        NSLog("[Parakatt] Chunked result (%@, %.2fs): %@", self.activeMode, result.durationSecs, result.text)
                    } else {
                        NSLog("[Parakatt] Empty chunked transcription (mode=%@)", self.activeMode)
                    }
                }
            } catch {
                bridge.cancelSession(sessionId: sessionId)
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                    NSLog("[Parakatt] Chunked transcription FAILED: %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Streaming

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

        // Snapshot the current buffer
        audioBufferLock.lock()
        let snapshot = audioBuffer
        audioBufferLock.unlock()

        guard snapshot.count >= minSamplesForStreaming else { return }

        // Limit snapshot to last 30 seconds to avoid OOM on very long recordings
        let maxSamples = 30 * 16000
        let trimmed = snapshot.count > maxSamples
            ? Array(snapshot.suffix(maxSamples))
            : snapshot

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
                        self.liveTranscription = result.text.isEmpty ? nil : result.text
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
