import Foundation
import ParakattCore

/// Drives the cache-aware streaming live preview path.
///
/// The audio capture service hands us 16 kHz mono samples on the
/// hardware tap thread; we accumulate them into a small ring and,
/// every time we have at least one native chunk worth of audio
/// (~560 ms for Nemotron 0.6B), we hand it off to a dedicated
/// background queue that calls `bridge.feedStreamingChunk`. The
/// Rust side runs LocalAgreement-2 and returns
/// `StreamingChunkResult { committed, tentative, newly_committed }`,
/// which we publish via the `onUpdate` callback.
///
/// The service is stateful — call `start(...)` once per recording,
/// `enqueue(samples)` from the audio callback, and `stop()` /
/// `cancel()` to release. Designed to be reusable across recordings.
final class LivePreviewService {
    /// Called on the main queue with the latest committed and
    /// tentative slices whenever the streaming model has emitted a
    /// new chunk.
    var onUpdate: ((_ committed: String, _ tentative: String, _ newlyCommitted: String) -> Void)?

    /// Called on the main queue when an unrecoverable error happens
    /// (model failed to start, repeated transcribe errors, etc.).
    var onError: ((String) -> Void)?

    private let bridge: CoreBridge
    private let workQueue = DispatchQueue(label: "parakatt.livepreview.worker", qos: .userInteractive)
    private let bufferLock = NSLock()

    private var pending: [Float] = []
    private var sessionId: String?
    private var nativeChunkSamples: Int = 0
    /// True while a feedStreamingChunk call is in flight on the
    /// worker queue. Prevents queue pile-up when the model is
    /// slower than the audio rate (we just keep accumulating into
    /// `pending` and feed it on the next free tick).
    private var inFlight = false
    private var consecutiveErrors: Int = 0
    private let maxConsecutiveErrors: Int = 5

    // MARK: - Telemetry

    /// Wall-clock time when the session was started, used to compute
    /// first-token latency.
    private var sessionStartTime: Date?
    /// Wall-clock time when the first non-empty committed text was
    /// observed for this session. nil until that happens.
    private var firstTokenTime: Date?
    /// Total chunks fed to the model since session start.
    private var chunksProcessed: Int = 0
    /// Total feed latency (sum) for averaging.
    private var totalFeedLatencySecs: Double = 0
    /// Number of times the committed prefix changed (= LA-2 advanced).
    /// Counted as a churn metric so we can spot if the model is
    /// flickering instead of converging.
    private var committedAdvances: Int = 0
    private var lastCommittedLength: Int = 0

    init(bridge: CoreBridge) {
        self.bridge = bridge
    }

    /// Whether the bridge has a streaming model loaded. The caller
    /// should check this before deciding to wire the live preview
    /// path — if false, fall back to the buffered v3 + LA-2 path.
    var isStreamingAvailable: Bool {
        bridge.isStreamingModelLoaded()
    }

    /// Start a new preview session. Returns the session id so the
    /// caller can pass the same one to bridge.startSession (if it
    /// also wants to use the commit path with the same id) — or
    /// just to track the session.
    @discardableResult
    func start() throws -> String {
        let id = UUID().uuidString
        try bridge.startStreamingSession(sessionId: id)
        bufferLock.lock()
        sessionId = id
        pending.removeAll(keepingCapacity: true)
        consecutiveErrors = 0
        sessionStartTime = Date()
        firstTokenTime = nil
        chunksProcessed = 0
        totalFeedLatencySecs = 0
        committedAdvances = 0
        lastCommittedLength = 0
        let native = Int(bridge.streamingNativeChunkSamples())
        // Default to 8000 (500 ms) if the provider didn't report a
        // size — that's a reasonable lower bound for any model.
        nativeChunkSamples = native > 0 ? native : 8_000
        bufferLock.unlock()
        NSLog("[Parakatt] LivePreview started (session=%@, chunk=%d samples)", id, nativeChunkSamples)
        return id
    }

    /// Append samples to the worker's pending buffer and kick the
    /// worker if it isn't already busy.
    func enqueue(_ samples: [Float]) {
        bufferLock.lock()
        guard sessionId != nil else {
            bufferLock.unlock()
            return
        }
        pending.append(contentsOf: samples)
        let shouldDispatch = !inFlight && pending.count >= nativeChunkSamples
        if shouldDispatch {
            inFlight = true
        }
        bufferLock.unlock()

        if shouldDispatch {
            workQueue.async { [weak self] in
                self?.drainOne()
            }
        }
    }

    private func drainOne() {
        bufferLock.lock()
        guard let id = sessionId, pending.count >= nativeChunkSamples else {
            inFlight = false
            bufferLock.unlock()
            return
        }
        // Take exactly one native chunk per call. If more is buffered
        // we'll come back on the next enqueue (or recurse below).
        let chunk = Array(pending.prefix(nativeChunkSamples))
        pending.removeFirst(nativeChunkSamples)
        bufferLock.unlock()

        let feedStart = Date()
        do {
            let result = try bridge.feedStreamingChunk(
                sessionId: id,
                audioSamples: chunk
            )
            let feedSecs = Date().timeIntervalSince(feedStart)
            consecutiveErrors = 0
            chunksProcessed += 1
            totalFeedLatencySecs += feedSecs
            // Track first-token latency.
            if firstTokenTime == nil && !result.committedText.isEmpty {
                firstTokenTime = Date()
                if let start = sessionStartTime {
                    let latencyMs = Int(firstTokenTime!.timeIntervalSince(start) * 1000)
                    NSLog("[Parakatt] LivePreview first-token latency: %d ms", latencyMs)
                }
            }
            // Commit advance / churn.
            if result.committedText.count > lastCommittedLength {
                committedAdvances += 1
                lastCommittedLength = result.committedText.count
            } else if result.committedText.count < lastCommittedLength {
                // Shouldn't happen with LA-2's monotonic commits but
                // log it if it ever does.
                NSLog("[Parakatt] WARNING: committed text shrank from %d to %d chars",
                      lastCommittedLength, result.committedText.count)
                lastCommittedLength = result.committedText.count
            }
            // Periodic average feed latency log every 20 chunks.
            if chunksProcessed % 20 == 0 {
                let avgMs = Int((totalFeedLatencySecs / Double(chunksProcessed)) * 1000)
                NSLog("[Parakatt] LivePreview stats: chunks=%d avg_feed=%d ms commit_advances=%d",
                      chunksProcessed, avgMs, committedAdvances)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onUpdate?(
                    result.committedText,
                    result.tentativeText,
                    result.newlyCommittedText
                )
            }
        } catch {
            consecutiveErrors += 1
            NSLog("[Parakatt] LivePreview feed failed (%d/%d): %@",
                  consecutiveErrors, maxConsecutiveErrors, error.localizedDescription)
            if consecutiveErrors >= maxConsecutiveErrors {
                let msg = "Live preview disabled after \(maxConsecutiveErrors) consecutive failures: \(error.localizedDescription)"
                DispatchQueue.main.async { [weak self] in
                    self?.onError?(msg)
                }
                stopInternal()
                return
            }
        }

        // If more audio is already buffered, schedule another drain.
        bufferLock.lock()
        let stillHasChunk = pending.count >= nativeChunkSamples
        if stillHasChunk {
            // Stay inFlight=true and recurse on the same queue.
            bufferLock.unlock()
            workQueue.async { [weak self] in
                self?.drainOne()
            }
        } else {
            inFlight = false
            bufferLock.unlock()
        }
    }

    /// Finish the session and return the final committed transcript.
    /// Caller can use this as the canonical preview text after the
    /// hotkey is released.
    @discardableResult
    func stop() -> String {
        bufferLock.lock()
        let id = sessionId
        sessionId = nil
        pending.removeAll(keepingCapacity: true)
        inFlight = false
        bufferLock.unlock()

        guard let id else { return "" }
        do {
            return try bridge.finishStreamingSession(sessionId: id)
        } catch {
            NSLog("[Parakatt] LivePreview finish failed: %@", error.localizedDescription)
            return ""
        }
    }

    /// Cancel the session without returning text.
    func cancel() {
        bufferLock.lock()
        let id = sessionId
        sessionId = nil
        pending.removeAll(keepingCapacity: true)
        inFlight = false
        bufferLock.unlock()
        if let id { bridge.cancelStreamingSession(sessionId: id) }
    }

    private func stopInternal() {
        bufferLock.lock()
        let id = sessionId
        sessionId = nil
        pending.removeAll(keepingCapacity: true)
        inFlight = false
        bufferLock.unlock()
        if let id { bridge.cancelStreamingSession(sessionId: id) }
    }
}
