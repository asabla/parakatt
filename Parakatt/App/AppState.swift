import Foundation
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
    @Published var activeMode = "dictation"
    @Published var isModelLoaded = false
    @Published var errorMessage: String?

    // MARK: - Services

    private var audioCaptureService: AudioCaptureService?
    private var textInsertionService: TextInsertionService?
    private var contextService: ContextService?

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

        // Load the default model on a background thread (Metal/GPU init is heavy)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let bridge = self.bridge else { return }

            NSLog("[Parakatt] Loading parakeet model in background...")
            do {
                try bridge.loadModel("parakeet-tdt-0.6b-v2")
                DispatchQueue.main.async {
                    self.isModelLoaded = true
                    NSLog("[Parakatt] Model loaded — ready to transcribe")
                }
            } catch {
                DispatchQueue.main.async {
                    NSLog("[Parakatt] Model load failed: \(error) — transcription won't work until a model is loaded")
                }
            }
        }
    }

    func shutdown() {
        stopRecording()
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
        audioBufferLock.lock()
        audioBuffer.removeAll()
        audioBufferLock.unlock()

        do {
            try audioCaptureService?.startCapture()
            isRecording = true
            errorMessage = nil
            NSLog("[Parakatt] Recording STARTED (modelLoaded=%d)", isModelLoaded ? 1 : 0)
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            NSLog("[Parakatt] Recording FAILED: %@", error.localizedDescription)
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        audioCaptureService?.stopCapture()
        isRecording = false
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

    // MARK: - Model management

    func loadModel(_ modelId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.bridge?.loadModel(modelId)
                DispatchQueue.main.async {
                    self.isModelLoaded = true
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

    // MARK: - Processing

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

    // MARK: - Audio buffer

    private var sampleCount = 0

    private func appendAudioSamples(_ samples: [Float]) {
        audioBufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        let total = audioBuffer.count
        audioBufferLock.unlock()

        sampleCount += 1
        if sampleCount % 50 == 1 {
            NSLog("[Parakatt] Audio callback #%d, buffer: %d samples (%.1fs)", sampleCount, total, Double(total) / 16000.0)
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
