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

    /// Called when a new chunk is transcribed (new text, accumulated text).
    var onChunkTranscribed: ((String, String) -> Void)?
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
    /// - Parameter processID: Specific process to capture system audio from, or nil for all.
    func start(processID: pid_t? = nil) throws {
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

        // Start both audio captures.
        try micCapture.startCapture()
        try systemCapture.startCapture(processID: processID)

        isActive = true
        startTime = Date()
        chunkIndex = 0
        accumulatedText = ""

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
        guard mixBuffer.count >= Int(Double(sampleRate) * 1.0) else {
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
                chunkIndex: currentIndex
            )
            accumulatedText = result.accumulatedText
            DispatchQueue.main.async { [weak self] in
                self?.onChunkTranscribed?(result.text, result.accumulatedText)
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

    private func appendMicSamples(_ samples: [Float]) {
        micLock.lock()
        micPendingSamples.append(contentsOf: samples)
        micLock.unlock()
        mixPendingSamples()
    }

    private func appendSystemSamples(_ samples: [Float]) {
        systemLock.lock()
        systemPendingSamples.append(contentsOf: samples)
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
        for i in 0..<mixCount {
            // Additive mix with clipping protection.
            let sum = micPendingSamples[i] + systemPendingSamples[i]
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
        guard mixBuffer.count >= Int(Double(sampleRate) * 1.0) else {
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
                let result = try self.bridge.processChunk(
                    sessionId: self.sessionId,
                    audioSamples: chunkSamples,
                    sampleRate: self.sampleRate,
                    chunkIndex: currentIndex
                )
                DispatchQueue.main.async {
                    self.accumulatedText = result.accumulatedText
                    self.onChunkTranscribed?(result.text, result.accumulatedText)
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

        var remaining: [Float] = []
        if micPendingSamples.count > systemPendingSamples.count {
            // Mix what we can, then pass mic-only audio.
            let mixCount = systemPendingSamples.count
            for i in 0..<mixCount {
                let sum = micPendingSamples[i] + systemPendingSamples[i]
                remaining.append(max(-1.0, min(1.0, sum)))
            }
            remaining.append(contentsOf: micPendingSamples[mixCount...])
            micPendingSamples.removeAll()
            systemPendingSamples.removeAll()
        } else if systemPendingSamples.count > micPendingSamples.count {
            let mixCount = micPendingSamples.count
            for i in 0..<mixCount {
                let sum = micPendingSamples[i] + systemPendingSamples[i]
                remaining.append(max(-1.0, min(1.0, sum)))
            }
            remaining.append(contentsOf: systemPendingSamples[mixCount...])
            micPendingSamples.removeAll()
            systemPendingSamples.removeAll()
        } else {
            // Equal length — just mix normally.
            let count = micPendingSamples.count
            for i in 0..<count {
                let sum = micPendingSamples[i] + systemPendingSamples[i]
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
