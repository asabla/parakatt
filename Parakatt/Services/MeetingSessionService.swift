import Foundation
import ParakattCore

/// Orchestrates a meeting transcription session.
///
/// Captures mic + system audio simultaneously, mixes them into a single
/// stream, and dispatches 30-second chunks to the Rust engine for STT.
/// The accumulated transcript is available in real time and is persisted
/// on session finish.
@available(macOS 14.2, *)
class MeetingSessionService {
    // MARK: - Callbacks

    /// Called when a new chunk is transcribed (new text, accumulated text, segments).
    var onChunkTranscribed: ((String, String, [TimestampedSegment]) -> Void)?
    /// Called when the session finishes with the final result.
    var onSessionFinished: ((TranscriptionResult) -> Void)?
    /// Called if an error occurs during the session.
    var onError: ((String) -> Void)?

    // MARK: - Configuration

    /// Chunk size in seconds.
    private let chunkDurationSecs: Double = 30.0
    /// Overlap between chunks in seconds.
    private let overlapDurationSecs: Double = 2.0
    /// Sample rate (must match STT expectations).
    private let sampleRate: UInt32 = 16_000

    // MARK: - Audio sources

    private let micCapture = AudioCaptureService()
    private let systemCapture = SystemAudioCaptureService()

    // MARK: - State

    private let sessionId: String
    private let bridge: CoreBridge

    private var mixBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var chunkIndex: UInt32 = 0
    private var isActive = false
    private var chunkTimer: Timer?
    private var startTime: Date?

    /// Mode and context used for per-chunk LLM processing.
    private var activeMode: String = "dictation"
    private var activeContext: AppContextInfo?

    /// Accumulated full transcript (updated after each chunk).
    private(set) var accumulatedText: String = ""

    /// Elapsed time since session start.
    var elapsedTime: TimeInterval {
        guard let startTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    init(bridge: CoreBridge) {
        self.bridge = bridge
        self.sessionId = UUID().uuidString
    }

    // MARK: - Lifecycle

    /// Start the meeting transcription session.
    /// - Parameters:
    ///   - processID: Specific process to capture system audio from, or nil for all.
    ///   - mode: The active transcription mode (used for per-chunk LLM processing).
    ///   - context: App context (used for per-chunk LLM processing).
    func start(processID: pid_t? = nil, mode: String = "dictation", context: AppContextInfo? = nil) throws {
        guard !isActive else { return }

        // Start session in the Rust engine.
        try bridge.startSession(sessionId: sessionId)

        // Set up mic capture callback.
        micCapture.onAudioSamples = { [weak self] samples in
            self?.appendMicSamples(samples)
        }

        // Set up system audio capture callback.
        systemCapture.onAudioSamples = { [weak self] samples in
            self?.appendSystemSamples(samples)
        }

        // Start both audio captures. If either throws, unwind the
        // pieces that already started so we don't leak the Rust session
        // or leave one capture running on its own.
        do {
            try micCapture.startCapture()
        } catch {
            bridge.cancelSession(sessionId: sessionId)
            throw error
        }
        do {
            try systemCapture.startCapture(processID: processID)
        } catch {
            micCapture.stopCapture()
            bridge.cancelSession(sessionId: sessionId)
            throw error
        }

        isActive = true
        startTime = Date()
        chunkIndex = 0
        accumulatedText = ""
        activeMode = mode
        activeContext = context

        // Start the chunk dispatch timer on the main run loop.
        let chunkInterval = chunkDurationSecs - overlapDurationSecs
        chunkTimer = Timer.scheduledTimer(
            withTimeInterval: chunkInterval,
            repeats: true
        ) { [weak self] _ in
            self?.dispatchChunk()
        }

        NSLog("[Parakatt] Meeting session STARTED (id: %@)", sessionId)
    }

    /// Stop the meeting and finalize the transcription.
    func stop(mode: String, context: AppContextInfo?) {
        guard isActive else { return }
        isActive = false

        chunkTimer?.invalidate()
        chunkTimer = nil
        micCapture.stopCapture()
        systemCapture.stopCapture()

        // Process any remaining audio and finish the session on a background thread.
        // Both must happen sequentially on the same thread to avoid the final chunk
        // racing with session teardown.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Process the final chunk synchronously.
            self.processRemainingChunkSync()

            // Now finish the session (applies dictionary + LLM, persists).
            do {
                let result = try self.bridge.finishSession(
                    sessionId: self.sessionId,
                    mode: mode,
                    context: context
                )
                DispatchQueue.main.async {
                    self.onSessionFinished?(result)
                }
                NSLog("[Parakatt] Meeting session FINISHED (%.0fs, %d chunks)",
                      result.durationSecs, self.chunkIndex)
            } catch {
                DispatchQueue.main.async {
                    self.onError?("Failed to finish session: \(error.localizedDescription)")
                }
                NSLog("[Parakatt] Meeting finish FAILED: %@", error.localizedDescription)
            }
        }
    }

    /// Process any remaining audio in the buffer as a final chunk, synchronously.
    private func processRemainingChunkSync() {
        flushPendingSamples()

        let samplesPerChunk = Int(chunkDurationSecs * Double(sampleRate))

        bufferLock.lock()
        guard mixBuffer.count >= Int(Double(sampleRate) * 0.1) else {
            bufferLock.unlock()
            NSLog("[Parakatt] Final chunk: not enough audio (%.1fs), skipping",
                  Double(mixBuffer.count) / Double(sampleRate))
            return
        }
        let chunkSamples = Array(mixBuffer.prefix(samplesPerChunk))
        mixBuffer.removeAll()
        bufferLock.unlock()

        let currentIndex = chunkIndex
        chunkIndex += 1

        do {
            let result = try bridge.processChunk(
                sessionId: sessionId,
                audioSamples: chunkSamples,
                sampleRate: sampleRate,
                chunkIndex: currentIndex,
                mode: activeMode,
                context: activeContext
            )
            // Pull the running accumulated text on demand instead of
            // having Rust clone it on every chunk.
            let acc = (try? bridge.getSessionText(sessionId: sessionId)) ?? accumulatedText
            accumulatedText = acc
            if let llmErr = result.llmError {
                NSLog("[Parakatt] Final chunk %d LLM degraded (raw text used): %@", currentIndex, llmErr)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onChunkTranscribed?(result.text, acc, result.segments)
            }
            NSLog("[Parakatt] Final chunk %d processed: %d samples", currentIndex, chunkSamples.count)
        } catch {
            NSLog("[Parakatt] Final chunk %d failed: %@", currentIndex, error.localizedDescription)
        }
    }

    /// Cancel the session without saving.
    func cancel() {
        guard isActive else { return }
        isActive = false

        chunkTimer?.invalidate()
        chunkTimer = nil
        micCapture.stopCapture()
        systemCapture.stopCapture()
        bridge.cancelSession(sessionId: sessionId)

        NSLog("[Parakatt] Meeting session CANCELLED")
    }

    // MARK: - Audio mixing

    /// Mic and system audio arrive on different threads. We buffer them
    /// independently and mix on dispatch. For simplicity, we use a single
    /// buffer and additive mixing — both sources write to the same buffer.
    /// Since chunks are 30s and mic/system audio are both 16kHz mono, the
    /// interleaving is naturally aligned.

    private var micPendingSamples: [Float] = []
    private var systemPendingSamples: [Float] = []
    private let micLock = NSLock()
    private let systemLock = NSLock()

    /// Per-source gain applied before summing the two streams.
    /// −6 dB (≈ 0.5012) is the standard headroom for an additive mix
    /// of two roughly-equal sources. Without this, mic + system audio
    /// sums clipped constantly when both speakers were talking,
    /// distorting the audio fed into Parakeet.
    private static let mixGainPerSource: Float = 0.5012

    /// Maximum pending samples per source (60s at 16kHz). Prevents unbounded
    /// memory growth if one source is much faster than the other.
    private let maxPendingSamples = 60 * 16_000

    private func appendMicSamples(_ samples: [Float]) {
        micLock.lock()
        micPendingSamples.append(contentsOf: samples)
        if micPendingSamples.count > maxPendingSamples {
            let excess = micPendingSamples.count - maxPendingSamples
            micPendingSamples.removeFirst(excess)
            NSLog("[Parakatt] WARNING: Mic pending buffer overflow — dropped %d samples (%.1fs)", excess, Double(excess) / Double(sampleRate))
        }
        micLock.unlock()
        mixPendingSamples()
    }

    private func appendSystemSamples(_ samples: [Float]) {
        systemLock.lock()
        systemPendingSamples.append(contentsOf: samples)
        if systemPendingSamples.count > maxPendingSamples {
            let excess = systemPendingSamples.count - maxPendingSamples
            systemPendingSamples.removeFirst(excess)
            NSLog("[Parakatt] WARNING: System pending buffer overflow — dropped %d samples (%.1fs)", excess, Double(excess) / Double(sampleRate))
        }
        systemLock.unlock()
        mixPendingSamples()
    }

    /// Mix the shorter of the two pending buffers into the main mix buffer.
    /// This ensures we don't get too far ahead on one source while the other
    /// lags. Remaining samples stay pending until the other source catches up.
    private func mixPendingSamples() {
        micLock.lock()
        systemLock.lock()

        let mixCount = min(micPendingSamples.count, systemPendingSamples.count)
        guard mixCount > 0 else {
            systemLock.unlock()
            micLock.unlock()
            return
        }

        var mixed = [Float](repeating: 0, count: mixCount)
        let g = Self.mixGainPerSource
        for i in 0..<mixCount {
            // −6 dB per source before sum so a fully-loud mic + a
            // fully-loud system source still fits in [-1, 1] without
            // hard clipping. Saturation guard remains as a safety net.
            let sum = micPendingSamples[i] * g + systemPendingSamples[i] * g
            mixed[i] = max(-1.0, min(1.0, sum))
        }

        micPendingSamples.removeFirst(mixCount)
        systemPendingSamples.removeFirst(mixCount)

        systemLock.unlock()
        micLock.unlock()

        bufferLock.lock()
        mixBuffer.append(contentsOf: mixed)
        bufferLock.unlock()
    }

    // MARK: - Chunk dispatch

    private func dispatchChunk() {
        // Flush any remaining pending samples (one source may be ahead).
        flushPendingSamples()

        let samplesPerChunk = Int(chunkDurationSecs * Double(sampleRate))
        let overlapSamples = Int(overlapDurationSecs * Double(sampleRate))

        bufferLock.lock()
        guard mixBuffer.count >= Int(Double(sampleRate) * 0.1) else {
            // Less than 1 second of audio — skip this chunk.
            bufferLock.unlock()
            return
        }

        // Take the chunk (up to chunk size).
        let chunkSamples = Array(mixBuffer.prefix(samplesPerChunk))

        // Keep the overlap for the next chunk.
        let consumed = max(0, chunkSamples.count - overlapSamples)
        if consumed > 0 {
            mixBuffer.removeFirst(consumed)
        }
        bufferLock.unlock()

        let currentIndex = chunkIndex
        chunkIndex += 1

        // Process chunk on a background thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, self.isActive || currentIndex == self.chunkIndex - 1 else { return }

            do {
                // Chunk N (N > 0) carries the previous chunk's last
                // `overlapDurationSecs` of audio at its head — pass
                // that as the overlap window so Rust can apply
                // time-based middle-token merging instead of falling
                // back to text matching.
                let chunkOverlap = currentIndex > 0 ? self.overlapDurationSecs : 0.0
                let result = try self.bridge.processChunk(
                    sessionId: self.sessionId,
                    audioSamples: chunkSamples,
                    sampleRate: self.sampleRate,
                    chunkIndex: currentIndex,
                    chunkOverlapSecs: chunkOverlap,
                    mode: self.activeMode,
                    context: self.activeContext
                )
                // Pull running accumulated text on demand.
                let acc = (try? self.bridge.getSessionText(sessionId: self.sessionId)) ?? ""
                if let llmErr = result.llmError {
                    NSLog("[Parakatt] Chunk %d LLM degraded (raw text used): %@", currentIndex, llmErr)
                }
                DispatchQueue.main.async {
                    self.accumulatedText = acc
                    self.onChunkTranscribed?(result.text, acc, result.segments)
                }
            } catch {
                NSLog("[Parakatt] Chunk %d failed: %@", currentIndex, error.localizedDescription)
            }
        }
    }

    /// Flush any remaining pending samples from one source that the other
    /// hasn't caught up with yet. Uses zero-padding for the missing source.
    private func flushPendingSamples() {
        micLock.lock()
        systemLock.lock()

        let g = Self.mixGainPerSource
        var remaining: [Float] = []
        if micPendingSamples.count > systemPendingSamples.count {
            // Mix what we can, then pass mic-only audio (no gain
            // reduction needed for the solo tail since there's nothing
            // to clip against).
            let mixCount = systemPendingSamples.count
            for i in 0..<mixCount {
                let sum = micPendingSamples[i] * g + systemPendingSamples[i] * g
                remaining.append(max(-1.0, min(1.0, sum)))
            }
            remaining.append(contentsOf: micPendingSamples[mixCount...])
            micPendingSamples.removeAll()
            systemPendingSamples.removeAll()
        } else if systemPendingSamples.count > micPendingSamples.count {
            let mixCount = micPendingSamples.count
            for i in 0..<mixCount {
                let sum = micPendingSamples[i] * g + systemPendingSamples[i] * g
                remaining.append(max(-1.0, min(1.0, sum)))
            }
            remaining.append(contentsOf: systemPendingSamples[mixCount...])
            micPendingSamples.removeAll()
            systemPendingSamples.removeAll()
        } else {
            // Equal length — just mix normally.
            let count = micPendingSamples.count
            for i in 0..<count {
                let sum = micPendingSamples[i] * g + systemPendingSamples[i] * g
                remaining.append(max(-1.0, min(1.0, sum)))
            }
            micPendingSamples.removeAll()
            systemPendingSamples.removeAll()
        }

        systemLock.unlock()
        micLock.unlock()

        if !remaining.isEmpty {
            bufferLock.lock()
            mixBuffer.append(contentsOf: remaining)
            bufferLock.unlock()
        }
    }
}
