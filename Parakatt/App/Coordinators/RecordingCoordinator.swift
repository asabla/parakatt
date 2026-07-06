import Foundation

/// Push-to-talk + single-recording UI state.
///
/// Owns the @Published surface that drives the recording overlay,
/// menu bar, and live-preview UI, plus the raw push-to-talk audio tail
/// that feeds single-shot, preview, and incremental chunking paths.
@MainActor
final class RecordingCoordinator: ObservableObject {
    /// Sample rate expected by the STT pipeline.
    let sampleRate: UInt32 = 16_000
    /// Seconds before transitioning from single-shot preview to incremental chunking.
    let firstChunkDelaySecs: TimeInterval = 1.0
    /// How often the PTT dispatch timer wakes up. The dispatch policy, not this timer, gates chunk rate.
    let pttDispatchTickSecs: TimeInterval = 1.5
    /// Minimum audio required before dispatching an incremental PTT chunk.
    let pttMinChunkSecs: Double = 2.0
    /// Hard upper bound on incremental PTT chunk size.
    let pttMaxChunkSecs: Double = 12.0
    /// Consecutive silent callbacks required before treating the current point as a natural pause.
    let pttPauseSilenceCallbacks: Int = 5
    /// Overlap between consecutive chunks to avoid cutting words at boundaries.
    let overlapDurationSecs: Double = 2.0
    /// Grace period after hotkey release before stopping audio capture.
    let captureDrainDelaySecs: TimeInterval = 0.6
    /// Interval between buffered live-preview updates while recording.
    let streamingInterval: TimeInterval = 2.0
    /// Minimum samples needed before the first buffered live preview.
    var minSamplesForStreaming: Int { Int(sampleRate) }
    /// Minimum new audio since the last preview pass before re-transcribing.
    let minNewSamplesForRestream = 8000

    /// True while the user is actively recording (held or toggled on).
    @Published var isRecording = false
    /// True while a chunk is being transcribed / inserted (UI shows spinner).
    @Published var isProcessing = false
    /// Last full transcription result, shown in the menu bar and history.
    @Published var lastTranscription: String?
    /// Best-current text during recording — composed from committed +
    /// tentative slices for streaming mode, or per-chunk accumulated
    /// text for the buffered v3 path.
    @Published var liveTranscription: String?

    /// Current input level (0…1), driven by audio tap callbacks.
    @Published var currentAudioLevel: Float = 0
    /// True if the input has been below the silence threshold long
    /// enough that the user probably forgot to unmute.
    @Published var silenceDetected = false
    /// True if the input is consistently clipping — surfaces a "lower
    /// your mic gain" hint in the overlay.
    @Published var audioClippingDetected = false

    /// Latest committed text from the LocalAgreement-2 stream.
    /// Stable, never revised by the live preview path.
    @Published var livePreviewCommitted: String = ""
    /// Latest tentative tail from the LocalAgreement-2 stream.
    /// Renders in lighter style; expected to flicker.
    @Published var livePreviewTentative: String = ""

    struct AppendResult {
        let totalSamples: Int
        let shouldFeedLivePreview: Bool
        let speechResumed: Bool
        let longRecordingWarningMinutes: Double?
        let callbackNumberToLog: Int?
    }

    struct PttChunk {
        let index: UInt32
        let samples: [Float]
    }

    enum CapturedAudioValidation {
        case valid(durationSecs: Double)
        case empty
        case tooShort(durationSecs: Double)
    }

    private var audioBuffer: [Float] = []
    private let audioBufferLock = NSLock()
    private var sampleCount = 0
    /// Number of consecutive near-silent audio callbacks.
    private var silentCallbackCount = 0
    /// Threshold: callbacks are ~every 100ms, so 50 = ~5 seconds of silence.
    private let silenceCallbackThreshold = 50
    /// After this many consecutive silent callbacks (~10 s) we stop
    /// feeding the streaming preview model to save CPU/battery.
    private let livePreviewSleepCallbacks = 100
    /// Threshold for warning about long push-to-talk recordings (5 minutes).
    private var longRecordingWarningSamples: Int { 5 * 60 * Int(sampleRate) }
    private var longRecordingWarned = false

    private var streamingTimer: Timer?
    private var pttChunkTimer: Timer?
    private nonisolated(unsafe) let pttChunkLock = NSLock()
    /// True while the audio engine is still running for a brief grace period after hotkey release.
    private var isCaptureDraining = false
    /// Session ID for incremental processing (nil = short recording, single-shot).
    private var pttSessionId: String?
    private var pttChunkIndex: UInt32 = 0
    /// Accumulated text from processed chunks (used to compose live display).
    private var pttAccumulatedText: String?
    private var isStreamTranscribing = false
    /// Sample count of the last buffer we ran the streaming preview on.
    /// Used to skip re-transcribing essentially the same audio when the
    /// user goes silent for a few seconds.
    private var lastStreamingSampleCount = 0
    /// Buffered preview LocalAgreement-2 session id, set when the fallback
    /// path takes over (no Nemotron loaded). Cleared on stopRecording.
    private var bufferedPreviewSessionId: String?

    func resetForNewRecording() {
        sampleCount = 0
        silentCallbackCount = 0
        silenceDetected = false
        audioClippingDetected = false
        longRecordingWarned = false
        currentAudioLevel = 0
        stopStreamingUpdates()
        resetPttState()
        bufferedPreviewSessionId = nil
        clearBuffer()
    }

    func clearPreviewDisplay() {
        liveTranscription = nil
        livePreviewCommitted = ""
        livePreviewTentative = ""
    }

    func applyPreviewText(committed: String, tentative: String) {
        livePreviewCommitted = committed
        livePreviewTentative = tentative
        let display = tentative.isEmpty
            ? committed
            : (committed.isEmpty ? tentative : "\(committed) \(tentative)")
        liveTranscription = display.isEmpty ? nil : display
    }

    func applyFinalPreviewText(_ text: String) {
        guard !text.isEmpty else { return }
        livePreviewCommitted = text
        livePreviewTentative = ""
        liveTranscription = text
    }

    func applyBufferedPreview(committedText: String, tentativeText: String) {
        // Compose committed chunk text with the current unprocessed tail.
        let chunkPrefix = pttAccumulatedText ?? ""
        let committedFull: String
        if chunkPrefix.isEmpty {
            committedFull = committedText
        } else if committedText.isEmpty {
            committedFull = chunkPrefix
        } else {
            committedFull = "\(chunkPrefix) \(committedText)"
        }

        applyPreviewText(committed: committedFull, tentative: tentativeText)
    }

    func canStartRecording() -> Bool {
        !isRecording && !isCaptureDraining
    }

    func beginRecording() {
        // Set immediately to prevent races with rapid start/stop.
        isRecording = true
        resetForNewRecording()
    }

    func markRecordingStartFailed() {
        isRecording = false
    }

    func beginStopRecording() {
        stopPttChunkTimer()
        stopStreamingUpdates()
        isRecording = false
        currentAudioLevel = 0
        beginCaptureDrain()
    }

    func beginIncrementalTailProcessing() {
        isProcessing = true
    }

    func completePttSession(text: String) {
        isProcessing = false
        liveTranscription = nil
        lastTranscription = text
        clearPttAccumulatedText()
        clearPttSession()
    }

    func failPttSession() {
        isProcessing = false
        liveTranscription = nil
        clearPttAccumulatedText()
        clearPttSession()
    }

    func beginSingleShotProcessing() {
        isProcessing = true
    }

    func completeSingleShot(text: String) {
        isProcessing = false
        lastTranscription = text
    }

    func failSingleShot() {
        isProcessing = false
    }

    func clearLiveTranscription() {
        liveTranscription = nil
    }

    func beginCaptureDrain() {
        isCaptureDraining = true
    }

    func finishCaptureDrain() {
        isCaptureDraining = false
    }

    nonisolated func withPttChunkLock<T>(_ body: () throws -> T) rethrows -> T {
        pttChunkLock.lock()
        defer { pttChunkLock.unlock() }
        return try body()
    }

    func clearBuffer() {
        audioBufferLock.lock()
        audioBuffer.removeAll()
        audioBufferLock.unlock()
    }

    func drainBuffer() -> [Float] {
        audioBufferLock.lock()
        let samples = audioBuffer
        audioBuffer.removeAll()
        audioBufferLock.unlock()
        return samples
    }

    func snapshotBuffer() -> [Float] {
        audioBufferLock.lock()
        let samples = audioBuffer
        audioBufferLock.unlock()
        return samples
    }

    func validateCapturedAudio(_ samples: [Float], minimumDurationSecs: Double = 0.5) -> CapturedAudioValidation {
        guard !samples.isEmpty else { return .empty }

        let durationSecs = Double(samples.count) / Double(sampleRate)
        guard durationSecs >= minimumDurationSecs else {
            return .tooShort(durationSecs: durationSecs)
        }

        return .valid(durationSecs: durationSecs)
    }

    func appendAudioSamples(_ samples: [Float], isRecording: Bool, livePreviewActive: Bool) -> AppendResult {
        audioBufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        let total = audioBuffer.count
        audioBufferLock.unlock()

        let shouldFeedLivePreview = livePreviewActive && silentCallbackCount < livePreviewSleepCallbacks

        let longWarning: Double?
        if total > longRecordingWarningSamples && !longRecordingWarned {
            longRecordingWarned = true
            longWarning = Double(total) / Double(sampleRate) / 60.0
        } else {
            longWarning = nil
        }

        // Compute RMS for audio level visualization.
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(max(samples.count, 1)))
        // Normalize: typical speech RMS ~0.01-0.1, scale up for display.
        let normalized = min(rms * 10, 1.0)
        let smoothed = 0.3 * currentAudioLevel + 0.7 * normalized

        // Detect a "speech resumed after silence" transition so preview can
        // kick immediately instead of waiting for the next timer tick.
        let wasSilentBefore = silentCallbackCount > 5
        if rms < 0.001 {
            silentCallbackCount += 1
        } else {
            silentCallbackCount = 0
        }
        let speechResumed = isRecording && wasSilentBefore && rms >= 0.001

        // Detect clipping: any sample at +/-1.0 means the signal is saturated.
        let maxAmp = samples.lazy.map { abs($0) }.max() ?? 0
        let clipping = maxAmp >= 0.99
        currentAudioLevel = smoothed
        silenceDetected = silentCallbackCount >= silenceCallbackThreshold
        if clipping { audioClippingDetected = true }

        sampleCount += 1
        let callbackToLog = sampleCount % 50 == 1 ? sampleCount : nil

        return AppendResult(
            totalSamples: total,
            shouldFeedLivePreview: shouldFeedLivePreview,
            speechResumed: speechResumed,
            longRecordingWarningMinutes: longWarning,
            callbackNumberToLog: callbackToLog
        )
    }

    func prepareNextPttChunk() -> PttChunk? {
        let minSamples = Int(pttMinChunkSecs * Double(sampleRate))
        let maxSamples = Int(pttMaxChunkSecs * Double(sampleRate))
        let overlapSamples = Int(overlapDurationSecs * Double(sampleRate))
        let chunkIndex = pttChunkIndex

        audioBufferLock.lock()
        let bufferLen = audioBuffer.count
        guard bufferLen >= minSamples else {
            audioBufferLock.unlock()
            return nil
        }
        let speakerPaused = silentCallbackCount >= pttPauseSilenceCallbacks
        let bufferAtCap = bufferLen >= maxSamples
        guard speakerPaused || bufferAtCap else {
            audioBufferLock.unlock()
            return nil
        }

        // Take up to maxSamples worth — variable-length chunks.
        let take = min(bufferLen, maxSamples)
        let chunkSamples = Array(audioBuffer.prefix(take))
        // First chunk has no prior chunk to overlap with — consume everything
        // to prevent the tail from re-processing the same audio.
        let consumed = chunkIndex == 0
            ? chunkSamples.count
            : max(0, chunkSamples.count - overlapSamples)
        if consumed > 0 {
            audioBuffer.removeFirst(consumed)
        }
        audioBufferLock.unlock()

        pttChunkIndex += 1
        return PttChunk(index: chunkIndex, samples: chunkSamples)
    }

    func startStreamingUpdates(interval: TimeInterval, onTick: @escaping () -> Void) {
        streamingTimer?.invalidate()
        lastStreamingSampleCount = 0
        streamingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            onTick()
        }
    }

    func stopStreamingUpdates() {
        streamingTimer?.invalidate()
        streamingTimer = nil
        lastStreamingSampleCount = 0
    }

    func startPttTransitionTimer(delay: TimeInterval, onFire: @escaping () -> Void) {
        stopPttChunkTimer()
        pttChunkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            onFire()
        }
    }

    func startPttDispatchTimer(interval: TimeInterval, onTick: @escaping () -> Void) {
        stopPttChunkTimer()
        pttChunkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            onTick()
        }
    }

    func stopPttChunkTimer() {
        pttChunkTimer?.invalidate()
        pttChunkTimer = nil
    }

    func resetPttState() {
        pttSessionId = nil
        pttChunkIndex = 0
        pttAccumulatedText = nil
        stopPttChunkTimer()
    }

    func beginPttSessionDispatch(id: String, onDispatch: @escaping () -> Void) {
        pttSessionId = id
        onDispatch()
        startPttDispatchTimer(interval: pttDispatchTickSecs, onTick: onDispatch)
    }

    func clearPttSession() {
        pttSessionId = nil
    }

    func currentPttSessionId() -> String? {
        pttSessionId
    }

    func currentPttChunkIndex() -> UInt32 {
        pttChunkIndex
    }

    func applyPttAccumulatedText(_ text: String) {
        let newAccumulated = text.isEmpty ? nil : text
        pttAccumulatedText = newAccumulated
        if let newAccumulated {
            liveTranscription = newAccumulated
        }
    }

    func clearPttAccumulatedText() {
        pttAccumulatedText = nil
    }

    func resetPreviewWatermark() {
        lastStreamingSampleCount = 0
    }

    func shouldRunBufferedPreview(snapshotCount: Int, minSamples: Int, minNewSamples: Int) -> Bool {
        guard snapshotCount >= minSamples else { return false }

        // Special case: if the buffer shrank since the last pass (a chunk
        // fired and consumed audio), always run the preview because there is a
        // fresh tail to inspect.
        if snapshotCount < lastStreamingSampleCount {
            lastStreamingSampleCount = snapshotCount
            return true
        }

        let newSamples = snapshotCount - lastStreamingSampleCount
        if lastStreamingSampleCount > 0 && newSamples < minNewSamples {
            return false
        }

        lastStreamingSampleCount = snapshotCount
        return true
    }

    func currentBufferedPreviewSessionId() -> String? {
        bufferedPreviewSessionId
    }

    func takeBufferedPreviewSessionId() -> String? {
        let id = bufferedPreviewSessionId
        bufferedPreviewSessionId = nil
        return id
    }

    func ensureBufferedPreviewSession(bridge: CoreBridge) -> String? {
        if bufferedPreviewSessionId == nil {
            let id = UUID().uuidString
            do {
                try bridge.bufferedPreviewStart(sessionId: id)
                bufferedPreviewSessionId = id
            } catch {
                NSLog("[Parakatt] Buffered preview start failed: %@", error.localizedDescription)
            }
        }
        return bufferedPreviewSessionId
    }

    func beginStreamTranscribing() -> Bool {
        guard !isStreamTranscribing else { return false }
        isStreamTranscribing = true
        return true
    }

    func finishStreamTranscribing() {
        isStreamTranscribing = false
    }
}
