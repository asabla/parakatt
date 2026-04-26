import AppKit
import Combine
import HotKey
import os.log
import ParakattCore
import UserNotifications

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
    @Published var silenceDetected = false
    @Published var audioClippingDetected = false

    // MARK: - Live preview (streaming) state

    /// Latest committed text from the LocalAgreement-2 stream.
    /// Stable, never revised by the live preview path.
    @Published var livePreviewCommitted: String = ""
    /// Latest tentative tail from the LocalAgreement-2 stream.
    /// Renders in lighter style; expected to flicker.
    @Published var livePreviewTentative: String = ""

    // Meeting state
    @Published var isMeetingActive = false
    @Published var isMeetingPaused = false
    @Published var meetingElapsedTime: TimeInterval = 0
    @Published var meetingTranscription: String?
    @Published var meetingLatestChunk: String?
    @Published var meetingSegments: [TimestampedSegment] = []
    /// Absolute-timestamp index (seconds) where the latest chunk's segments
    /// begin. Lets the live view highlight "what just arrived" without
    /// needing a separate copy of the latest chunk's segments.
    @Published var meetingLatestChunkStartSecs: Double?
    @Published var meetingAudioStatus: MeetingAudioStatus = .unknown
    /// Live peak amplitude of the mic capture during a meeting, 0…1.
    /// Driven from MeetingSessionService.onMicLevel. Smoothed client-side
    /// to avoid visual jitter on short silences.
    @Published var meetingMicLevel: Float = 0
    /// Seconds of audio required before the first chunk transcribes.
    /// Surfaced to the UI so it can draw a "until first batch" progress bar.
    var meetingFirstChunkSecs: Double { 30.0 }
    /// Seconds between subsequent chunk dispatches after the first.
    var meetingChunkIntervalSecs: Double { 28.0 }

    /// When the system-audio side first started reporting silent/empty.
    /// Used to decide when to escalate to a user-visible warning.
    private var systemSilentSince: Date?
    /// Rolling signal-quality threshold (dBFS) below which a source counts
    /// as "silent". -60 dBFS matches the tap health threshold.
    private let meetingSilenceDbfsThreshold: Double = -60.0
    /// Seconds of continuous system-silent before we surface a user warning.
    private let meetingSilenceWarnAfterSecs: TimeInterval = 15

    // Behavior settings
    @Published var autoPaste = true
    @Published var showRecordingOverlay = true
    @Published var debugMode = false
    @Published var speakerLabelsEnabled = false

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
    /// True while the audio engine is still running for a brief grace period after hotkey release.
    private var isCaptureDraining = false

    /// Seconds before transitioning from single-shot preview to incremental chunking.
    private let firstChunkDelaySecs: TimeInterval = 1.0
    /// How often the dispatch timer wakes up. Each tick decides
    /// whether the audio buffer is in a state where it should be
    /// flushed as a chunk (see `dispatchPttChunk` for the policy).
    /// Short interval keeps the loop responsive; the actual chunk
    /// rate is gated by the policy, not the timer.
    private let pttDispatchTickSecs: TimeInterval = 1.5
    /// Minimum audio (in seconds) required before we'll dispatch
    /// even an early chunk. Below this Parakeet's accuracy drops
    /// noticeably and we waste a model call.
    private let pttMinChunkSecs: Double = 2.0
    /// Hard upper bound on chunk size — if the speaker hasn't paused
    /// for this long we force-dispatch anyway so the user isn't
    /// stuck waiting for a natural break.
    private let pttMaxChunkSecs: Double = 12.0
    /// Number of consecutive silent audio callbacks (~100 ms each)
    /// that must have elapsed before we treat the current moment as
    /// a "natural pause" and flush. ~5 callbacks ≈ 500 ms.
    private let pttPauseSilenceCallbacks: Int = 5

    // MARK: - Engine bridge

    private var bridge: CoreBridge?
    private var engineReady = false

    /// Cache-aware streaming live preview (Nemotron). Owned by the
    /// app, started/stopped per recording. Receives committed +
    /// tentative slices via its onUpdate callback.
    private var livePreview: LivePreviewService?
    /// True while the streaming preview is active for the current
    /// recording. Used by appendAudioSamples to decide whether to
    /// also feed the buffered v3 path.
    private var livePreviewActive = false

    // MARK: - Lifecycle

    /// Initialize the Rust engine, audio services, and load settings from config.
    func initializeEngine() {
        // Set up file logging
        FileLogService.shared.logStartup()

        // Set up services
        textInsertionService = TextInsertionService()
        contextService = ContextService()
        requestNotificationPermission()

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

            // Build the live preview service. It's a no-op until
            // start() is called and noop-fails gracefully if no
            // streaming model is loaded.
            if let bridge = bridge {
                let preview = LivePreviewService(bridge: bridge)
                preview.onUpdate = { [weak self] committed, tentative, _ in
                    guard let self else { return }
                    self.livePreviewCommitted = committed
                    self.livePreviewTentative = tentative
                    let display = tentative.isEmpty
                        ? committed
                        : (committed.isEmpty ? tentative : "\(committed) \(tentative)")
                    self.liveTranscription = display.isEmpty ? nil : display
                }
                preview.onError = { [weak self] msg in
                    NSLog("[Parakatt] LivePreview disabled: %@", msg)
                    self?.livePreviewActive = false
                }
                livePreview = preview
            }

            // Load behavior settings from config
            if let ap = try? bridge?.getAutoPaste() { autoPaste = ap }
            if let so = try? bridge?.getShowOverlay() { showRecordingOverlay = so }
            if let dm = try? bridge?.getDebugMode() { debugMode = dm }
            if let sl = try? bridge?.getSpeakerLabelsEnabled() { speakerLabelsEnabled = sl }

            // Load API key from Keychain (not config file)
            loadLlmApiKeyFromKeychain()

            // Load preferred audio source from config
            if let bundleId = try? bridge?.getPreferredAudioSource() {
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

        // Find the offline commit-path model (parakeet-*) and the
        // optional streaming preview model (nemotron-*). Both can be
        // downloaded; we register both.
        let offlineModel = models.first(where: { $0.downloaded && $0.id.hasPrefix("parakeet-") })
        let streamingModel = models.first(where: { $0.downloaded && $0.id.hasPrefix("nemotron-") })

        if let model = offlineModel {
            // Load the downloaded model on a background thread (Metal/GPU init is heavy)
            let modelId = model.id
            let streamingId = streamingModel?.id
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self, let bridge = self.bridge else { return }

                NSLog("[Parakatt] Loading offline model '%@' in background...", modelId)
                do {
                    try bridge.loadModel(modelId)
                    DispatchQueue.main.async {
                        self.isModelLoaded = true
                        self.activeModelId = modelId
                        NSLog("[Parakatt] Offline model loaded — ready to transcribe")
                    }
                } catch {
                    DispatchQueue.main.async {
                        NSLog("[Parakatt] Offline model load failed: \(error) — transcription won't work until a model is loaded")
                    }
                }

                // Optionally register the streaming preview model
                // alongside it. Failure here is non-fatal — the
                // commit path still works.
                if let streamingId {
                    do {
                        try bridge.loadModel(streamingId)
                        NSLog("[Parakatt] Streaming model registered: %@", streamingId)
                    } catch {
                        NSLog("[Parakatt] Streaming model register failed: %@", error.localizedDescription)
                    }
                }
            }
        } else {
            NSLog("[Parakatt] No offline model downloaded — user needs to download one")
            needsModelDownload = true
        }
    }

    /// Clean up all running sessions and audio capture on app termination.
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

    /// Start a push-to-talk recording session via AVAudioEngine.
    func startRecording() {
        guard !isRecording, !isCaptureDraining else {
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

        sampleCount = 0
        silentCallbackCount = 0
        silenceDetected = false
        audioClippingDetected = false
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
            currentAudioLevel = 0
            liveTranscription = nil
            errorMessage = nil
            livePreviewCommitted = ""
            livePreviewTentative = ""

            // Try to start the cache-aware streaming preview. If
            // the streaming model isn't loaded (non-English user
            // who didn't download Nemotron, or first launch), this
            // gracefully falls back to the buffered v3 + LA-2 path
            // via the throwaway streaming preview below.
            if let preview = livePreview, preview.isStreamingAvailable {
                do {
                    _ = try preview.start()
                    livePreviewActive = true
                    NSLog("[Parakatt] Live preview: streaming path active")
                } catch {
                    livePreviewActive = false
                    NSLog("[Parakatt] Live preview start failed: %@ — falling back to buffered preview", error.localizedDescription)
                }
            } else {
                livePreviewActive = false
            }

            // Start throwaway buffered preview for immediate feedback.
            // This is the fallback path for users without the streaming
            // model, AND it runs alongside the streaming preview as a
            // safety net while the streaming model warms up.
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
            isRecording = false
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            NSLog("[Parakatt] Recording FAILED: %@", error.localizedDescription)
        }
    }

    /// Grace period (seconds) after hotkey release before stopping audio capture.
    /// Allows the AVAudioEngine tap to deliver remaining buffered samples (~256ms).
    /// Grace period after the user releases the hotkey before we
    /// stop the audio engine. AVAudioEngine has a hardware buffer
    /// in flight; if we tear down too quickly the last few hundred
    /// milliseconds of audio (often the trailing word of the user's
    /// final sentence) never make it into our buffer. 600 ms covers
    /// the typical CoreAudio buffer + a margin for slow speakers.
    private let captureDrainDelaySecs: TimeInterval = 0.6

    /// Stop recording and process the captured audio through the STT pipeline.
    func stopRecording() {
        guard isRecording else { return }

        pttChunkTimer?.invalidate()
        pttChunkTimer = nil
        stopStreamingUpdates()
        isRecording = false
        currentAudioLevel = 0
        isCaptureDraining = true

        // Keep audio capture running briefly so the hardware buffer can drain,
        // then stop capture and process the tail.
        DispatchQueue.main.asyncAfter(deadline: .now() + captureDrainDelaySecs) { [weak self] in
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
        isCaptureDraining = false

        // Tear down the live preview session and grab its final
        // committed text. This becomes the canonical preview while
        // the commit pipeline finishes processing the buffer tail.
        if livePreviewActive {
            let finalText = livePreview?.stop() ?? ""
            livePreviewActive = false
            if !finalText.isEmpty {
                livePreviewCommitted = finalText
                livePreviewTentative = ""
                liveTranscription = finalText
            }
        }

        // Also tear down the buffered preview LA-2 session if it
        // was used (when no streaming model was loaded).
        if let bpId = bufferedPreviewSessionId {
            let final = (try? bridge?.bufferedPreviewFinish(sessionId: bpId)) ?? ""
            bufferedPreviewSessionId = nil
            if !final.isEmpty {
                livePreviewCommitted = final
                livePreviewTentative = ""
                liveTranscription = final
            }
        }

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

                // Wait for any in-flight chunk to complete, then run the
                // tail under the same lock. Scoped so the lock is released
                // before the (potentially slow) finishSession call below,
                // even if a future edit adds an early return inside.
                do {
                    self.pttChunkLock.lock()
                    defer { self.pttChunkLock.unlock() }

                    if remainingSamples.count >= Int(self.sttSampleRate / 10) {
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
                        self.pttAccumulatedText = nil
                        self.lastTranscription = result.text
                        self.pttSessionId = nil
                        self.errorMessage = nil

                        if !result.text.isEmpty {
                            if self.autoPaste {
                                let inserted = self.textInsertionService?.insertText(result.text) ?? false
                                if !inserted {
                                    self.errorMessage = "Could not paste text — transcription copied to clipboard"
                                }
                            }
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
                errorMessage = "No audio captured — check microphone permission in System Settings > Privacy & Security"
                return
            }

            let durationSecs = Double(samples.count) / Double(sttSampleRate)
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
    @Published var llmApiKey: String = "" {
        didSet {
            // Persist API key to Keychain instead of config file
            KeychainService.set(llmApiKey, forKey: "llm-api-key")
        }
    }

    func loadLlmApiKeyFromKeychain() {
        if let key = KeychainService.get("llm-api-key") {
            llmApiKey = key
        }
    }

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

    func testLlmConnection() -> String {
        do {
            return try bridge?.testLlmConnection() ?? "No engine"
        } catch {
            return error.localizedDescription
        }
    }

    func listModes() -> [ModeConfig] {
        bridge?.listModes() ?? []
    }

    func saveMode(_ mode: ModeConfig) {
        do {
            try bridge?.saveMode(mode)
        } catch {
            errorMessage = "Failed to save mode: \(error.localizedDescription)"
        }
    }

    // MARK: - Profiles

    func listProfiles() -> [String] {
        bridge?.listProfiles() ?? []
    }

    func saveProfile(_ name: String) {
        do {
            try bridge?.saveProfile(name)
            NSLog("[Parakatt] Saved profile: %@", name)
        } catch {
            errorMessage = "Failed to save profile: \(error.localizedDescription)"
        }
    }

    func loadProfile(_ name: String) {
        do {
            try bridge?.loadProfile(name)
            // Reload settings from the new config
            if let ap = try? bridge?.getAutoPaste() { autoPaste = ap }
            if let so = try? bridge?.getShowOverlay() { showRecordingOverlay = so }
            if let dm = try? bridge?.getDebugMode() { debugMode = dm }
            if let sl = try? bridge?.getSpeakerLabelsEnabled() { speakerLabelsEnabled = sl }
            loadLlmApiKeyFromKeychain()
            NSLog("[Parakatt] Loaded profile: %@", name)
        } catch {
            errorMessage = "Failed to load profile: \(error.localizedDescription)"
        }
    }

    func deleteProfile(_ name: String) {
        do {
            try bridge?.deleteProfile(name)
        } catch {
            errorMessage = "Failed to delete profile: \(error.localizedDescription)"
        }
    }

    func getAppModeDefaults() -> [(String, String)] {
        do {
            return try bridge?.getAppModeDefaults() ?? []
        } catch {
            NSLog("[Parakatt] Failed to get app mode defaults: %@", error.localizedDescription)
            return []
        }
    }

    func setAppModeDefault(bundleId: String, mode: String) {
        do {
            try bridge?.setAppModeDefault(bundleId: bundleId, mode: mode)
        } catch {
            NSLog("[Parakatt] Failed to set app mode default: %@", error.localizedDescription)
        }
    }

    func deleteMode(_ name: String) {
        do {
            try bridge?.deleteMode(name)
        } catch {
            errorMessage = "Failed to delete mode: \(error.localizedDescription)"
        }
    }

    func getStatistics() -> [(String, String)] {
        do {
            return try bridge?.getStatistics() ?? []
        } catch {
            NSLog("[Parakatt] Failed to get statistics: %@", error.localizedDescription)
            return []
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
        guard let config = try? bridge.getHotkeyConfig() else {
            return (.space, [.option], "hold")
        }
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

    // MARK: - Behavior settings

    func setAutoPaste(_ enabled: Bool) {
        autoPaste = enabled
        do {
            try bridge?.setAutoPaste(enabled)
        } catch {
            NSLog("[Parakatt] Failed to save auto_paste setting: %@", error.localizedDescription)
        }
    }

    func setDebugMode(_ enabled: Bool) {
        debugMode = enabled
        do {
            try bridge?.setDebugMode(enabled)
        } catch {
            NSLog("[Parakatt] Failed to save debug_mode setting: %@", error.localizedDescription)
        }
    }

    func setSpeakerLabelsEnabled(_ enabled: Bool) {
        speakerLabelsEnabled = enabled
        do {
            try bridge?.setSpeakerLabelsEnabled(enabled)
        } catch {
            NSLog("[Parakatt] Failed to save speaker_labels_enabled setting: %@", error.localizedDescription)
        }
    }

    func setShowOverlay(_ enabled: Bool) {
        showRecordingOverlay = enabled
        do {
            try bridge?.setShowOverlay(enabled)
        } catch {
            NSLog("[Parakatt] Failed to save show_overlay setting: %@", error.localizedDescription)
        }
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
            errorMessage = "Engine not ready — download and load a model in Settings first"
            return
        }

        let session = MeetingSessionService(bridge: bridge)

        session.onChunkTranscribed = { [weak self] newText, accumulated, segments in
            guard let self else { return }
            self.meetingLatestChunk = newText
            self.meetingTranscription = accumulated
            if !segments.isEmpty {
                // Segments carry absolute-to-session timestamps already.
                // Track where the latest chunk starts so the live view can
                // highlight the new arrivals.
                let chunkStart = segments.first?.startSecs
                self.meetingSegments.append(contentsOf: segments)
                self.meetingLatestChunkStartSecs = chunkStart
            }
        }

        session.onChunkHealth = { [weak self] micDbfs, sysDbfs in
            self?.updateMeetingAudioStatus(micDbfs: micDbfs, sysDbfs: sysDbfs)
        }

        session.onSystemAudioHealth = { [weak self] health in
            self?.applySystemAudioHealth(health)
        }

        session.onMicLevel = { [weak self] peak in
            guard let self else { return }
            // Exponential moving average to smooth the bars without losing
            // responsiveness. Fast attack, slower release.
            let prev = self.meetingMicLevel
            let target = max(0, min(1, peak))
            let alpha: Float = target > prev ? 0.6 : 0.2
            self.meetingMicLevel = prev * (1 - alpha) + target * alpha
        }

        session.onSessionFinished = { [weak self] result in
            self?.isMeetingActive = false
            self?.meetingElapsedTimer?.invalidate()
            self?.meetingElapsedTimer = nil
            self?.meetingTranscription = result.text
            self?.meetingLatestChunk = nil
            self?.meetingLatestChunkStartSecs = nil
            self?.meetingAudioStatus = .unknown
            self?.meetingMicLevel = 0
            self?.isMeetingPaused = false
            self?.systemSilentSince = nil
            self?.sendTranscriptionNotification(preview: result.text, source: "meeting")
            NSLog("[Parakatt] Meeting finished: %.0fs, %d chars", result.durationSecs, result.text.count)
        }

        session.onError = { [weak self] message in
            self?.isMeetingActive = false
            self?.meetingElapsedTimer?.invalidate()
            self?.meetingElapsedTimer = nil
            self?.meetingAudioStatus = .error(message)
            self?.errorMessage = message
        }

        meetingSession = session
        isMeetingActive = true
        isMeetingPaused = false
        meetingTranscription = nil
        meetingLatestChunk = nil
        meetingLatestChunkStartSecs = nil
        meetingSegments = []
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
            try session.start(
                processID: selectedAudioSourcePID,
                mode: activeMode,
                context: context,
                speakerLabelsEnabled: speakerLabelsEnabled
            )
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
                    try session.start(
                        processID: nil,
                        mode: activeMode,
                        context: context,
                        speakerLabelsEnabled: speakerLabelsEnabled
                    )
                    return
                } catch {
                    // Fall through to error handling below
                }
            }

            isMeetingActive = false
            meetingElapsedTimer?.invalidate()
            meetingElapsedTimer = nil

            if let audioErr = error as? SystemAudioCaptureError, case .permissionDenied = audioErr {
                meetingAudioStatus = .permissionDenied
                promptForSystemAudioPermission()
            } else {
                meetingAudioStatus = .error(error.localizedDescription)
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
        isMeetingPaused = false
        meetingElapsedTimer?.invalidate()
        meetingElapsedTimer = nil
        meetingTranscription = nil
        meetingLatestChunk = nil
        meetingLatestChunkStartSecs = nil
        meetingSegments = []
        meetingAudioStatus = .unknown
        meetingMicLevel = 0
        systemSilentSince = nil
    }

    /// Pause audio capture without ending the Rust session. The user keeps
    /// looking at what they've captured so far; resume to continue.
    @available(macOS 14.2, *)
    func pauseMeeting() {
        guard isMeetingActive, !isMeetingPaused else { return }
        meetingSession?.pause()
        isMeetingPaused = true
    }

    @available(macOS 14.2, *)
    func resumeMeeting() {
        guard isMeetingActive, isMeetingPaused else { return }
        do {
            try meetingSession?.resume()
            isMeetingPaused = false
        } catch {
            errorMessage = "Failed to resume meeting: \(error.localizedDescription)"
        }
    }

    /// Apply a per-chunk RMS sample to the meeting audio-status state machine.
    /// Runs on the main thread (callback is already marshalled there).
    private func updateMeetingAudioStatus(micDbfs: Double?, sysDbfs: Double?) {
        let micSilent = (micDbfs ?? -.infinity) < meetingSilenceDbfsThreshold
        let sysSilent = (sysDbfs ?? -.infinity) < meetingSilenceDbfsThreshold

        // If the existing status is a terminal "permissionDenied" / "error",
        // leave it — subsequent chunk health can't contradict those.
        if case .permissionDenied = meetingAudioStatus { return }
        if case .error = meetingAudioStatus { return }

        if micSilent && sysSilent {
            meetingAudioStatus = .bothSilent
            systemSilentSince = systemSilentSince ?? Date()
        } else if sysSilent {
            let since = systemSilentSince ?? Date()
            systemSilentSince = since
            meetingAudioStatus = .systemSilent(since: since)
            if Date().timeIntervalSince(since) >= meetingSilenceWarnAfterSecs {
                if errorMessage == nil {
                    errorMessage = "No audio from other apps detected. If this is a meeting, confirm the other app is playing to the selected output device."
                }
            }
        } else {
            meetingAudioStatus = .healthy
            systemSilentSince = nil
        }
    }

    /// Apply a tap-level SystemAudioHealth sample. Note: the per-chunk RMS
    /// path (updateMeetingAudioStatus) is the source of truth for "is the
    /// transcript going to be mic-only?". This only escalates to .systemEmpty
    /// when the tap itself reports persistent empty buffers — that's a
    /// distinct failure mode (wrong output device, not just quiet audio).
    private func applySystemAudioHealth(_ health: SystemAudioHealth) {
        if case .permissionDenied = meetingAudioStatus { return }
        if case .error = meetingAudioStatus { return }

        switch health {
        case .empty(let forSeconds) where forSeconds >= meetingSilenceWarnAfterSecs:
            meetingAudioStatus = .systemEmpty
            if errorMessage == nil {
                errorMessage = "System-audio tap is delivering empty buffers. This usually means the selected output device isn't the one your meeting app is using."
            }
        case .empty(let forSeconds) where forSeconds >= 2.0:
            // Intermediate state: tap isn't delivering yet but it's early
            // days. Let the user know we're mic-only for now without
            // escalating all the way to a hard error.
            let since = systemSilentSince ?? Date()
            systemSilentSince = since
            if case .systemEmpty = meetingAudioStatus { return }
            if case .bothSilent = meetingAudioStatus { return }
            meetingAudioStatus = .systemSilent(since: since)
        case .silent(let forSeconds) where forSeconds >= 2.0:
            let since = systemSilentSince ?? Date()
            systemSilentSince = since
            if case .systemEmpty = meetingAudioStatus { return }
            if case .bothSilent = meetingAudioStatus { return }
            meetingAudioStatus = .systemSilent(since: since)
        case .ok:
            systemSilentSince = nil
            meetingAudioStatus = .healthy
        default:
            break
        }
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
        do {
            try bridge?.deleteTranscription(id: id)
            NSLog("[Parakatt] Deleted transcription: %@", id)
        } catch {
            NSLog("[Parakatt] Failed to delete transcription %@: %@", id, error.localizedDescription)
        }
    }

    func deleteTranscriptions(ids: [String]) -> Int {
        do {
            let count = try bridge?.deleteTranscriptions(ids: ids) ?? 0
            NSLog("[Parakatt] Bulk deleted %d transcriptions", count)
            return Int(count)
        } catch {
            NSLog("[Parakatt] Failed to bulk delete: %@", error.localizedDescription)
            return 0
        }
    }

    func getTranscriptionSegments(id: String) -> [TimestampedSegment] {
        (try? bridge?.getTranscriptionSegments(id: id)) ?? []
    }

    // MARK: - Model management

    func loadModel(_ modelId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let signpostID = OSSignpostID(log: signpostLog)
            os_signpost(.begin, log: signpostLog, name: "LoadModel", signpostID: signpostID, "%{public}s", modelId)
            defer { os_signpost(.end, log: signpostLog, name: "LoadModel", signpostID: signpostID) }

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

        guard let progress = try? bridge.getDownloadProgress() else { return }
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
            let signpostID = OSSignpostID(log: signpostLog)
            os_signpost(.begin, log: signpostLog, name: "Transcribe", signpostID: signpostID, "samples: %d", samples.count)
            defer { os_signpost(.end, log: signpostLog, name: "Transcribe", signpostID: signpostID) }

            guard let self, let bridge = self.bridge else {
                DispatchQueue.main.async { self?.isProcessing = false }
                return
            }

            let context = self.contextService?.currentContext()

            // Resolve mode: use per-app default if configured, otherwise global active mode
            let effectiveMode: String
            if let bundleId = context?.appBundleId,
               let resolved = try? bridge.resolveModeForApp(bundleId: bundleId) {
                effectiveMode = resolved
            } else {
                effectiveMode = self.activeMode
            }

            do {
                let result = try bridge.transcribe(
                    audioSamples: samples,
                    sampleRate: 16000,
                    mode: effectiveMode,
                    context: context
                )

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastTranscription = result.text
                    self.errorMessage = nil

                    if !result.text.isEmpty {
                        if self.autoPaste {
                            let inserted = self.textInsertionService?.insertText(result.text) ?? false
                            if !inserted {
                                self.errorMessage = "Could not paste text — transcription copied to clipboard"
                            }
                        }
                        self.sendTranscriptionNotification(preview: result.text, source: "push_to_talk")
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

        // Set up repeating timer that wakes every pttDispatchTickSecs
        // and decides whether the audio buffer is in a state where it
        // should be flushed as a commit chunk. Policy lives in
        // dispatchPttChunk: dispatch when (a) buffer ≥ pttMinChunkSecs
        // AND (the speaker has been silent ≥ pttPauseSilenceCallbacks
        // OR buffer ≥ pttMaxChunkSecs).
        pttChunkTimer = Timer.scheduledTimer(
            withTimeInterval: pttDispatchTickSecs,
            repeats: true
        ) { [weak self] _ in
            self?.dispatchPttChunk()
        }

        NSLog("[Parakatt] Incremental session started (id: %@)", sessionId)
    }

    /// VAD-aware chunk dispatch policy.
    ///
    /// On every timer tick (every `pttDispatchTickSecs`), evaluate
    /// whether the audio buffer is in a state where we should flush
    /// it to the commit pipeline:
    ///
    ///   * If the buffer holds less than `pttMinChunkSecs` of audio,
    ///     do nothing — the model wastes work on too-short clips.
    ///   * Otherwise, dispatch when EITHER
    ///       - the speaker has been silent for at least
    ///         `pttPauseSilenceCallbacks` consecutive audio
    ///         callbacks (~500 ms), giving us a natural sentence
    ///         boundary, OR
    ///       - the buffer has reached `pttMaxChunkSecs`, the hard
    ///         upper bound that prevents the user being stuck on a
    ///         non-stop monologue.
    ///
    /// Chunks become variable-length and naturally aligned to
    /// pauses, which is dramatically more responsive than the old
    /// fixed 30 s × 28 s timer.
    private func dispatchPttChunk() {
        guard let sessionId = pttSessionId, isRecording else { return }

        let minSamples = Int(pttMinChunkSecs * Double(sttSampleRate))
        let maxSamples = Int(pttMaxChunkSecs * Double(sttSampleRate))
        let overlapSamples = Int(overlapDurationSecs * Double(sttSampleRate))

        audioBufferLock.lock()
        let bufferLen = audioBuffer.count
        guard bufferLen >= minSamples else {
            audioBufferLock.unlock()
            return
        }
        let speakerPaused = silentCallbackCount >= pttPauseSilenceCallbacks
        let bufferAtCap = bufferLen >= maxSamples
        guard speakerPaused || bufferAtCap else {
            audioBufferLock.unlock()
            return
        }

        // Take up to maxSamples worth — variable-length chunks.
        let take = min(bufferLen, maxSamples)
        let chunkSamples = Array(audioBuffer.prefix(take))
        // First chunk has no prior chunk to overlap with — consume everything
        // to prevent the tail from re-processing the same audio.
        let consumed = pttChunkIndex == 0
            ? chunkSamples.count
            : max(0, chunkSamples.count - overlapSamples)
        if consumed > 0 {
            audioBuffer.removeFirst(consumed)
        }
        audioBufferLock.unlock()

        // The audio buffer just shrank — the buffered preview's
        // LA-2 is now operating on a shorter hypothesis than its
        // committed prefix, which would freeze the preview ("stuck
        // after ~2 sentences" bug). Reset the LA-2 state and the
        // gate watermark so the preview starts fresh on the new
        // (shorter) tail. The committed text we want the user to
        // see across chunk boundaries is `pttAccumulatedText`,
        // which is updated when the chunk processing returns.
        lastStreamingSampleCount = 0
        if let bpId = bufferedPreviewSessionId {
            try? bridge?.bufferedPreviewReset(sessionId: bpId)
        }

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
                // Pull the running accumulated text on demand instead of
                // having Rust clone it on every chunk.
                let acc = (try? bridge.getSessionText(sessionId: sessionId)) ?? ""
                if let llmErr = result.llmError {
                    NSLog("[Parakatt] PTT chunk %d LLM degraded (raw text used): %@", currentIndex, llmErr)
                }
                DispatchQueue.main.async {
                    if self.isRecording || self.isProcessing {
                        let newAccumulated = acc.isEmpty ? nil : acc
                        self.pttAccumulatedText = newAccumulated
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

    // MARK: - Streaming (throwaway preview for initial seconds)

    private var streamingTimer: Timer?
    /// Interval between live transcription updates while recording.
    private let streamingInterval: TimeInterval = 2.0
    /// Minimum samples needed before first live transcription (1s at 16kHz).
    private let minSamplesForStreaming = 16000

    private func startStreamingUpdates() {
        streamingTimer?.invalidate()
        lastStreamingSampleCount = 0
        streamingTimer = Timer.scheduledTimer(withTimeInterval: streamingInterval, repeats: true) { [weak self] _ in
            self?.updateLiveTranscription()
        }
    }

    private func stopStreamingUpdates() {
        streamingTimer?.invalidate()
        streamingTimer = nil
        lastStreamingSampleCount = 0
    }

    private var isStreamTranscribing = false
    /// Sample count of the last buffer we ran the streaming preview on.
    /// Used to skip re-transcribing essentially the same audio when the
    /// user goes silent for a few seconds — re-running Parakeet on a
    /// frozen buffer produces slightly different decodings each pass
    /// (the model isn't bit-deterministic on edge inputs), which made
    /// the live preview flicker between alternates.
    private var lastStreamingSampleCount: Int = 0
    /// Minimum new audio (in samples) required since the last preview
    /// pass before we'll re-transcribe. 0.5 s at 16 kHz — anything
    /// less is almost certainly just silence accumulating.
    private let minNewSamplesForRestream = 8000
    /// Buffered preview LocalAgreement-2 session id, set when the
    /// fallback path takes over (no Nemotron loaded). Cleared on
    /// stopRecording.
    private var bufferedPreviewSessionId: String?

    private func updateLiveTranscription() {
        guard isRecording, let bridge, !isStreamTranscribing else { return }

        // If the cache-aware streaming preview is doing its thing
        // we don't need to also run the buffered preview — they
        // both publish to livePreviewCommitted/Tentative and one
        // will dominate. Skip to save CPU.
        if livePreviewActive { return }

        // Snapshot the current buffer (unprocessed tail during incremental mode)
        audioBufferLock.lock()
        let snapshot = audioBuffer
        audioBufferLock.unlock()

        guard snapshot.count >= minSamplesForStreaming else { return }

        // Skip ticks where the buffer hasn't grown by enough audio to
        // matter. Without this, every 2 s of silence after speech
        // would re-decode the exact same waveform and surface a
        // flickering "alternate" decoding to the user.
        //
        // Special case: if the buffer SHRANK since the last pass
        // (a chunk fired and consumed audio) we always run the
        // preview — there's a fresh tail to look at. The chunk
        // dispatch path resets `lastStreamingSampleCount` to 0
        // when it consumes audio so we hit this branch by length
        // comparison even if the new buffer is small.
        if snapshot.count < lastStreamingSampleCount {
            // Buffer shrank — fresh window, allow this pass.
            lastStreamingSampleCount = snapshot.count
        } else {
            let newSamples = snapshot.count - lastStreamingSampleCount
            if lastStreamingSampleCount > 0 && newSamples < minNewSamplesForRestream {
                return
            }
            lastStreamingSampleCount = snapshot.count
        }

        // Limit snapshot to last 30 seconds to avoid OOM on very long recordings
        let maxSamples = 30 * 16000
        let trimmed = snapshot.count > maxSamples
            ? Array(snapshot.suffix(maxSamples))
            : snapshot

        // Lazily start a buffered preview LA-2 session for this
        // recording so the LA-2 commit policy persists across
        // every preview tick.
        if bufferedPreviewSessionId == nil {
            let id = UUID().uuidString
            do {
                try bridge.bufferedPreviewStart(sessionId: id)
                bufferedPreviewSessionId = id
            } catch {
                NSLog("[Parakatt] Buffered preview start failed: %@", error.localizedDescription)
            }
        }
        guard let bpSessionId = bufferedPreviewSessionId else { return }

        isStreamTranscribing = true

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            defer { self.isStreamTranscribing = false }

            do {
                let result = try bridge.bufferedPreviewUpdate(
                    sessionId: bpSessionId,
                    audioSamples: trimmed,
                    sampleRate: 16000
                )
                DispatchQueue.main.async {
                    if self.isRecording {
                        // Compose the display text. Three sources:
                        //   1. pttAccumulatedText: text already
                        //      committed by the chunk pipeline
                        //      (everything finalized in past chunks)
                        //   2. result.committedText: LA-2 stable
                        //      prefix from THIS preview window
                        //      (current unprocessed tail)
                        //   3. result.tentativeText: LA-2 unstable
                        //      tail (might still revise)
                        //
                        // Concatenate (1) + (2) into the committed
                        // surface and put (3) into tentative. The
                        // overlay's two-style display reads both.
                        let chunkPrefix = self.pttAccumulatedText ?? ""
                        let committedFull: String
                        if chunkPrefix.isEmpty {
                            committedFull = result.committedText
                        } else if result.committedText.isEmpty {
                            committedFull = chunkPrefix
                        } else {
                            committedFull = "\(chunkPrefix) \(result.committedText)"
                        }
                        self.livePreviewCommitted = committedFull
                        self.livePreviewTentative = result.tentativeText

                        let display: String
                        if result.tentativeText.isEmpty {
                            display = committedFull
                        } else if committedFull.isEmpty {
                            display = result.tentativeText
                        } else {
                            display = "\(committedFull) \(result.tentativeText)"
                        }
                        self.liveTranscription = display.isEmpty ? nil : display
                    }
                }
            } catch {
                // Silently ignore streaming errors
            }
        }
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("[Parakatt] Notification permission error: %@", error.localizedDescription)
            } else {
                NSLog("[Parakatt] Notification permission granted: %d", granted)
            }
        }
    }

    private func sendTranscriptionNotification(preview: String, source: String) {
        let content = UNMutableNotificationContent()
        content.title = source == "meeting" ? "Meeting transcription ready" : "Transcription complete"
        content.body = String(preview.prefix(100))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[Parakatt] Failed to send notification: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Audio buffer

    private var sampleCount = 0
    /// Number of consecutive near-silent audio callbacks.
    private var silentCallbackCount = 0
    /// Threshold: callbacks are ~every 100ms, so 50 = ~5 seconds of silence.
    private let silenceCallbackThreshold = 50
    /// After this many consecutive silent callbacks (~10 s) we stop
    /// feeding the streaming preview model to save CPU/battery. The
    /// silence→speech transition trigger in appendAudioSamples will
    /// resume it on the next sound.
    private let livePreviewSleepCallbacks: Int = 100

    /// Threshold for warning about long push-to-talk recordings (5 minutes).
    private let longRecordingWarningSamples = 5 * 60 * 16000
    private var longRecordingWarned = false

    private func appendAudioSamples(_ samples: [Float]) {
        audioBufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        let total = audioBuffer.count
        audioBufferLock.unlock()

        // Feed the cache-aware streaming preview in parallel. The
        // service does its own backpressure (drops if a feed is
        // already in flight) so we can call it on every audio
        // callback without queue pile-up. Power saver: if the user
        // has been silent for ≥livePreviewSleepCallbacks ticks
        // (~10 s) we skip feeding the model entirely. The silence→
        // speech transition trigger below will kick the service
        // again as soon as audio resumes.
        if livePreviewActive && silentCallbackCount < livePreviewSleepCallbacks {
            livePreview?.enqueue(samples)
        }

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
        // Track silence: if RMS is near zero, count consecutive silent callbacks.
        // Detect a "speech resumed after silence" transition so we can
        // kick the live preview immediately instead of waiting for the
        // next streaming-timer tick. Without this, the user got 0 to 2
        // seconds of "nothing happening" UI after they started speaking
        // again following a pause.
        let wasSilentBefore = silentCallbackCount > 5
        if rms < 0.001 {
            silentCallbackCount += 1
        } else {
            silentCallbackCount = 0
        }
        let speechResumed = wasSilentBefore && rms >= 0.001
        if speechResumed && isRecording {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Bypass the "buffer hasn't grown enough" gate by
                // resetting the watermark; we want this pass to run
                // even if only ~one frame of new audio has arrived.
                self.lastStreamingSampleCount = 0
                self.updateLiveTranscription()
            }
        }
        // Detect clipping: any sample at +/-1.0 means the signal is saturated
        let maxAmp = samples.lazy.map { abs($0) }.max() ?? 0
        let clipping = maxAmp >= 0.99
        DispatchQueue.main.async {
            self.currentAudioLevel = smoothed
            self.silenceDetected = self.silentCallbackCount >= self.silenceCallbackThreshold
            if clipping { self.audioClippingDetected = true }
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

    private func appSupportDirectory() -> URL {
        // Falls back to ~/Library/Application Support if the platform
        // ever decides to return an empty array (which it doesn't on
        // any sane macOS install, but `.first!` was a real crash path).
        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support")
    }

    private func modelsDirectory() -> URL {
        let dir = appSupportDirectory().appendingPathComponent("Parakatt/models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func configDirectory() -> URL {
        let dir = appSupportDirectory().appendingPathComponent("Parakatt/config")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
