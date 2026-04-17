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
    /// Called after each chunk dispatch with per-source signal levels. Lets
    /// the UI detect "only own voice captured" conditions while a meeting is
    /// still running (micRms > silence, systemRms at/near zero).
    /// `dbfs` values, or nil if that source delivered zero samples this window.
    var onChunkHealth: ((_ micDbfs: Double?, _ systemDbfs: Double?) -> Void)?
    /// Forwards periodic health from the system-audio tap itself. Emitted
    /// ~every 2s from the capture callback queue; hop to main before touching
    /// UI state. Useful for distinguishing "tap delivers empty buffers" from
    /// "tap delivers near-zero signal" from "all good".
    var onSystemAudioHealth: ((SystemAudioHealth) -> Void)?
    /// Peak mic amplitude for the last capture window, 0…1. Emitted every
    /// mic callback so the UI has a live audio-level indicator during the
    /// 28s before the first chunk transcribes.
    var onMicLevel: ((Float) -> Void)?
    /// Publicly visible chunk cadence so the UI can show a progress bar.
    var chunkIntervalSecs: Double { chunkDurationSecs - overlapDurationSecs }
    var firstChunkSecs: Double { chunkDurationSecs }

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
    /// Absolute timestamp at which capture started. Used as the reference
    /// point when a source has never delivered samples — otherwise the
    /// `lastSystemReceivedAt > 0` check in mixPendingSamples treats a
    /// never-delivering source as "not stale" and mic samples pile up.
    private var captureStartedAt: CFAbsoluteTime = 0
    /// Watchdog timer that fires every 2s independent of the system-audio
    /// tap's IOProc. On macOS 26 we've observed the tap register cleanly
    /// but never deliver callbacks — this timer surfaces that via
    /// onSystemAudioHealth so the UI doesn't sit at "Starting…" forever.
    private var healthWatchdog: Timer?

    /// Mode and context used for per-chunk LLM processing.
    private var activeMode: String = "dictation"
    private var activeContext: AppContextInfo?
    /// Remembered target process ID (if any) so pause/resume captures from
    /// the same source the session originally started with.
    private var activeProcessID: pid_t?

    /// Accumulated full transcript (updated after each chunk).
    private(set) var accumulatedText: String = ""

    /// Number of chunks that have been dispatched (mic+sys mixed).
    private var chunksDispatched: Int = 0
    /// Number of chunks that failed during processChunk. Used to detect
    /// the "every chunk silently failed" pathology that issue #23 was
    /// about — if all chunks fail, the user gets an error on stop()
    /// instead of a quietly empty transcript.
    private var chunksFailed: Int = 0

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

        // Forward tap-level health (empty/silent/ok) to the UI.
        systemCapture.onHealth = { [weak self] health in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onSystemAudioHealth?(health)
            }
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
        captureStartedAt = CFAbsoluteTimeGetCurrent()
        chunkIndex = 0
        chunksDispatched = 0
        chunksFailed = 0
        accumulatedText = ""
        activeMode = mode
        activeContext = context
        activeProcessID = processID

        // Start the chunk dispatch timer on the main run loop.
        let chunkInterval = chunkDurationSecs - overlapDurationSecs
        chunkTimer = Timer.scheduledTimer(
            withTimeInterval: chunkInterval,
            repeats: true
        ) { [weak self] _ in
            self?.dispatchChunk()
        }

        // Health watchdog — fires every 2s independent of the tap's IOProc.
        // On macOS 26.3+ we've seen the tap register without ever delivering
        // a callback; without this watchdog the UI would stay at .unknown
        // until the first chunk dispatches 28s later.
        healthWatchdog = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            self?.tickHealthWatchdog()
        }

        NSLog("[Parakatt] Meeting session STARTED (id: %@)", sessionId)
    }

    /// Pause audio capture without ending the Rust session.
    /// Leaves the chunk dispatch timer running so any audio already in the
    /// mix buffer still gets processed — but no new audio is captured until
    /// resume() is called. The session state (accumulated text, segments)
    /// is preserved.
    func pause() {
        guard isActive else { return }
        micCapture.stopCapture()
        systemCapture.stopCapture()
        NSLog("[Parakatt] Meeting session PAUSED")
    }

    /// Resume audio capture. Re-installs the sample callbacks and restarts
    /// both mic and system captures.
    func resume() throws {
        guard isActive else { return }
        micCapture.onAudioSamples = { [weak self] samples in
            self?.appendMicSamples(samples)
        }
        systemCapture.onAudioSamples = { [weak self] samples in
            self?.appendSystemSamples(samples)
        }
        systemCapture.onHealth = { [weak self] health in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onSystemAudioHealth?(health)
            }
        }
        try micCapture.startCapture()
        do {
            try systemCapture.startCapture(processID: activeProcessID)
        } catch {
            micCapture.stopCapture()
            throw error
        }
        NSLog("[Parakatt] Meeting session RESUMED")
    }

    /// Stop the meeting and finalize the transcription.
    func stop(mode: String, context: AppContextInfo?) {
        guard isActive else { return }
        isActive = false

        chunkTimer?.invalidate()
        chunkTimer = nil
        healthWatchdog?.invalidate()
        healthWatchdog = nil
        micCapture.stopCapture()
        systemCapture.stopCapture()

        // Process any remaining audio and finish the session on a background thread.
        // Both must happen sequentially on the same thread to avoid the final chunk
        // racing with session teardown.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Process the final chunk synchronously.
            self.processRemainingChunkSync()

            // Diagnostic: if every chunk we dispatched failed, the
            // session almost certainly produced nothing useful. Tell
            // the user *before* finish_session runs so they don't get
            // a misleading "session ended" message followed by silence.
            let dispatched = self.chunksDispatched
            let failed = self.chunksFailed
            if dispatched > 0 && failed == dispatched {
                let msg = "All \(dispatched) chunks failed to process — meeting transcript will be empty. Check logs."
                NSLog("[Parakatt] %@", msg)
                DispatchQueue.main.async {
                    self.onError?(msg)
                }
            } else if failed > 0 {
                NSLog("[Parakatt] Meeting completed with %d/%d chunks failed", failed, dispatched)
            }

            // Now finish the session (applies dictionary + LLM, persists).
            do {
                let result = try self.bridge.finishSession(
                    sessionId: self.sessionId,
                    mode: mode,
                    context: context,
                    source: "meeting"
                )
                DispatchQueue.main.async {
                    self.onSessionFinished?(result)
                }
                NSLog("[Parakatt] Meeting session FINISHED (%.0fs, %d chunks, %d failed)",
                      result.durationSecs, self.chunkIndex, failed)
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
                guard let self else { return }
                self.chunksDispatched += 1
                self.accumulatedText = acc
                self.onChunkTranscribed?(result.text, acc, result.segments)
            }
            NSLog("[Parakatt] Final chunk %d processed: %d samples", currentIndex, chunkSamples.count)
        } catch {
            NSLog("[Parakatt] Final chunk %d failed: %@", currentIndex, error.localizedDescription)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.chunksDispatched += 1
                self.chunksFailed += 1
                self.onError?("Final chunk \(currentIndex) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Cancel the session without saving.
    func cancel() {
        guard isActive else { return }
        isActive = false

        chunkTimer?.invalidate()
        chunkTimer = nil
        healthWatchdog?.invalidate()
        healthWatchdog = nil
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

    /// If one source hasn't delivered any samples for this long, drain the
    /// other source solo (no min-gate hold). This is what rescues a meeting
    /// where system-audio capture is silently delivering nothing — without
    /// this, mic samples pile up waiting for a system side that never shows.
    private let staleSourceThresholdSecs: Double = 1.0

    /// Absolute timestamp of the last delivered sample from each source.
    /// Protected by the respective per-source lock (written under lock,
    /// read inside mixPendingSamples which holds both).
    private var lastMicReceivedAt: CFAbsoluteTime = 0
    private var lastSystemReceivedAt: CFAbsoluteTime = 0

    /// Running per-source RMS accumulators for the current chunk window.
    /// Reset at each dispatchChunk. Used to surface per-source health to the UI.
    private var chunkMicSumSq: Double = 0
    private var chunkMicCount: Int = 0
    private var chunkSystemSumSq: Double = 0
    private var chunkSystemCount: Int = 0
    private let chunkRmsLock = NSLock()

    private func appendMicSamples(_ samples: [Float]) {
        let now = CFAbsoluteTimeGetCurrent()
        micLock.lock()
        lastMicReceivedAt = now
        micPendingSamples.append(contentsOf: samples)
        if micPendingSamples.count > maxPendingSamples {
            let excess = micPendingSamples.count - maxPendingSamples
            micPendingSamples.removeFirst(excess)
            NSLog("[Parakatt] WARNING: Mic pending buffer overflow — dropped %d samples (%.1fs)", excess, Double(excess) / Double(sampleRate))
        }
        micLock.unlock()

        var sumSq: Double = 0
        var peak: Float = 0
        for s in samples {
            sumSq += Double(s) * Double(s)
            let a = abs(s)
            if a > peak { peak = a }
        }
        chunkRmsLock.lock()
        chunkMicSumSq += sumSq
        chunkMicCount += samples.count
        chunkRmsLock.unlock()

        // Live mic level for the UI — gives the user immediate feedback
        // that their voice is being picked up even before the first chunk
        // transcribes at t=28s.
        let level = peak
        DispatchQueue.main.async { [weak self] in
            self?.onMicLevel?(level)
        }

        mixPendingSamples()
    }

    private func appendSystemSamples(_ samples: [Float]) {
        let now = CFAbsoluteTimeGetCurrent()
        systemLock.lock()
        lastSystemReceivedAt = now
        systemPendingSamples.append(contentsOf: samples)
        if systemPendingSamples.count > maxPendingSamples {
            let excess = systemPendingSamples.count - maxPendingSamples
            systemPendingSamples.removeFirst(excess)
            NSLog("[Parakatt] WARNING: System pending buffer overflow — dropped %d samples (%.1fs)", excess, Double(excess) / Double(sampleRate))
        }
        systemLock.unlock()

        var sumSq: Double = 0
        for s in samples { sumSq += Double(s) * Double(s) }
        chunkRmsLock.lock()
        chunkSystemSumSq += sumSq
        chunkSystemCount += samples.count
        chunkRmsLock.unlock()

        mixPendingSamples()
    }

    /// Mix pending samples into mixBuffer.
    ///
    /// Case 1 (steady state, both sources flowing): take the common prefix,
    /// apply per-source gain, sum, clamp. Leave the tail pending for the
    /// other source to catch up.
    ///
    /// Case 2 (one source stale > staleSourceThresholdSecs): drain the
    /// active source solo at full amplitude — don't hold mic samples hostage
    /// to a system-audio side that's empty-buffer delivering nothing.
    private func mixPendingSamples() {
        micLock.lock()
        systemLock.lock()

        let now = CFAbsoluteTimeGetCurrent()
        // Use captureStartedAt as the fallback reference when a source has
        // never delivered (lastReceivedAt == 0). Without this, a source
        // that never delivers is treated as "not stale" and samples from
        // the other source pile up waiting for it forever.
        let micReference = lastMicReceivedAt > 0 ? lastMicReceivedAt : captureStartedAt
        let systemReference = lastSystemReceivedAt > 0 ? lastSystemReceivedAt : captureStartedAt
        let micStale = captureStartedAt > 0 && (now - micReference) > staleSourceThresholdSecs
        let systemStale = captureStartedAt > 0 && (now - systemReference) > staleSourceThresholdSecs

        let common = min(micPendingSamples.count, systemPendingSamples.count)
        var mixed: [Float] = []
        if common > 0 {
            mixed.reserveCapacity(common)
            let g = Self.mixGainPerSource
            for i in 0..<common {
                let sum = micPendingSamples[i] * g + systemPendingSamples[i] * g
                mixed.append(max(-1.0, min(1.0, sum)))
            }
            micPendingSamples.removeFirst(common)
            systemPendingSamples.removeFirst(common)
        }

        // Solo-drain the active side if the other is stale.
        if systemStale && !micPendingSamples.isEmpty {
            // System hasn't delivered in > threshold; pass mic through solo.
            mixed.append(contentsOf: micPendingSamples)
            micPendingSamples.removeAll()
        } else if micStale && !systemPendingSamples.isEmpty {
            mixed.append(contentsOf: systemPendingSamples)
            systemPendingSamples.removeAll()
        }

        systemLock.unlock()
        micLock.unlock()

        guard !mixed.isEmpty else { return }
        bufferLock.lock()
        mixBuffer.append(contentsOf: mixed)
        bufferLock.unlock()
    }

    // MARK: - Chunk dispatch

    private func dispatchChunk() {
        // Flush any remaining pending samples (one source may be ahead).
        flushPendingSamples()
        emitPerSourceChunkHealth()

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
                    self.chunksDispatched += 1
                    self.accumulatedText = acc
                    self.onChunkTranscribed?(result.text, acc, result.segments)
                }
            } catch {
                NSLog("[Parakatt] Chunk %d failed: %@", currentIndex, error.localizedDescription)
                DispatchQueue.main.async {
                    self.chunksDispatched += 1
                    self.chunksFailed += 1
                    // Surface every chunk failure to the UI. The
                    // previous behavior was to swallow these into
                    // NSLog, which is exactly the silent-failure mode
                    // that hid issue #23.
                    self.onError?("Chunk \(currentIndex) failed: \(error.localizedDescription)")
                }
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

    /// Fires every 2s independent of the tap's IOProc. Surfaces a synthetic
    /// SystemAudioHealth so the UI transitions from .unknown to a meaningful
    /// state quickly even when the tap never delivers a callback.
    ///
    /// On macOS 26 we've observed the Core Audio process tap register
    /// successfully but never fire handleAudioCallback. Without this
    /// watchdog the only signal would be the per-chunk RMS, which doesn't
    /// land until t=28s when the first chunk dispatches.
    private func tickHealthWatchdog() {
        guard isActive, captureStartedAt > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let refSys = lastSystemReceivedAt > 0 ? lastSystemReceivedAt : captureStartedAt
        let sysSilentFor = now - refSys

        // Only synthesize a health signal if the tap itself hasn't been
        // speaking. If it has (lastSystemReceivedAt is recent), the real
        // tap's onHealth will drive the UI.
        if sysSilentFor > 2.0 {
            let synthetic: SystemAudioHealth = .empty(forSeconds: sysSilentFor)
            DispatchQueue.main.async { [weak self] in
                self?.onSystemAudioHealth?(synthetic)
            }
        }

        // Also drive mic-only mixing forward if the chunk timer hasn't
        // fired yet — keeps the mix buffer ticking so dispatchChunk has
        // audio ready even when system never delivers.
        mixPendingSamples()
    }

    /// Compute per-source RMS for the just-finished chunk window and hand it
    /// to the UI via onChunkHealth. Resets the accumulators so each chunk's
    /// reading is independent. This is how the UI notices "mic is hot but
    /// system is silent" without digging through NSLog.
    private func emitPerSourceChunkHealth() {
        chunkRmsLock.lock()
        let micSum = chunkMicSumSq
        let micCount = chunkMicCount
        let sysSum = chunkSystemSumSq
        let sysCount = chunkSystemCount
        chunkMicSumSq = 0
        chunkMicCount = 0
        chunkSystemSumSq = 0
        chunkSystemCount = 0
        chunkRmsLock.unlock()

        let micDbfs: Double?
        if micCount > 0 {
            let rms = sqrt(max(micSum / Double(micCount), 0))
            micDbfs = 20.0 * log10(max(rms, 1e-9))
        } else {
            micDbfs = nil
        }
        let sysDbfs: Double?
        if sysCount > 0 {
            let rms = sqrt(max(sysSum / Double(sysCount), 0))
            sysDbfs = 20.0 * log10(max(rms, 1e-9))
        } else {
            sysDbfs = nil
        }

        DispatchQueue.main.async { [weak self] in
            self?.onChunkHealth?(micDbfs, sysDbfs)
        }
    }
}
