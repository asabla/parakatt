import Foundation

/// Push-to-talk + single-recording UI state.
///
/// Owns the @Published surface that drives the recording overlay,
/// menu bar, and live-preview UI, plus the raw push-to-talk audio tail
/// that feeds single-shot, preview, and incremental chunking paths.
@MainActor
final class RecordingCoordinator: ObservableObject {
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
        let samples: [Float]
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
    private let longRecordingWarningSamples = 5 * 60 * 16000
    private var longRecordingWarned = false

    func resetForNewRecording() {
        sampleCount = 0
        silentCallbackCount = 0
        silenceDetected = false
        audioClippingDetected = false
        longRecordingWarned = false
        currentAudioLevel = 0
        clearBuffer()
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

    func appendAudioSamples(_ samples: [Float], isRecording: Bool, livePreviewActive: Bool) -> AppendResult {
        audioBufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        let total = audioBuffer.count
        audioBufferLock.unlock()

        let shouldFeedLivePreview = livePreviewActive && silentCallbackCount < livePreviewSleepCallbacks

        let longWarning: Double?
        if total > longRecordingWarningSamples && !longRecordingWarned {
            longRecordingWarned = true
            longWarning = Double(total) / 16000.0 / 60.0
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

    func preparePttChunk(
        minSamples: Int,
        maxSamples: Int,
        overlapSamples: Int,
        chunkIndex: UInt32,
        pauseSilenceCallbacks: Int
    ) -> PttChunk? {
        audioBufferLock.lock()
        let bufferLen = audioBuffer.count
        guard bufferLen >= minSamples else {
            audioBufferLock.unlock()
            return nil
        }
        let speakerPaused = silentCallbackCount >= pauseSilenceCallbacks
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

        return PttChunk(samples: chunkSamples)
    }
}
