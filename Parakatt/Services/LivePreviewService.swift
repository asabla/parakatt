import Foundation
import ParakattCore

protocol LivePreviewCore: AnyObject {
    func shouldUseStreamingPreview() -> Bool
    func streamingNativeChunkSamples() -> UInt32
    func startStreamingSession(sessionId: String) throws
    func feedStreamingChunk(sessionId: String, audioSamples: [Float]) throws -> StreamingChunkResult
    func finishStreamingSession(sessionId: String) throws -> String
    func cancelStreamingSession(sessionId: String)
}
extension CoreBridge: LivePreviewCore {}

/// Serial session lifecycle. Audio admission is bounded and never waits for inference.
final class LivePreviewService {
    var onUpdate: ((String, String, String) -> Void)?
    var onError: ((String) -> Void)?
    private let bridge: LivePreviewCore
    private let workQueue = DispatchQueue(label: "parakatt.livepreview.worker", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = FloatQueue()
    private var sessionID: String?
    private var generation: UInt64 = 0
    private var accepting = false
    private var scheduled = false
    private var chunkSize = 0
    private let capacity = 160_000

    init(bridge: LivePreviewCore) { self.bridge = bridge }
    var isStreamingAvailable: Bool { bridge.shouldUseStreamingPreview() }

    @discardableResult
    func start() throws -> String {
        cancel()
        guard isStreamingAvailable else { throw NSError(domain: "Parakatt", code: 1, userInfo: [NSLocalizedDescriptionKey: "Streaming preview is unavailable"]) }
        let size = Int(bridge.streamingNativeChunkSamples())
        guard size > 0 else { throw NSError(domain: "Parakatt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Streaming model has no chunk-size metadata"]) }
        let id = UUID().uuidString
        lock.lock()
        generation &+= 1
        let token = generation
        sessionID = id
        accepting = true
        scheduled = true
        chunkSize = size
        lock.unlock()
        workQueue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            do {
                try self.bridge.startStreamingSession(sessionId: id)
                self.drain(id: id, token: token, finishing: false)
            } catch { self.fail(id: id, token: token, message: error.localizedDescription) }
        }
        return id
    }

    func enqueue(_ samples: [Float]) {
        lock.lock()
        guard accepting, let id = sessionID else { lock.unlock(); return }
        let token = generation
        if pending.count + samples.count > capacity {
            accepting = false
            pending.removeAll()
            lock.unlock()
            workQueue.async { [weak self] in self?.fail(id: id, token: token, message: "Live preview could not keep up. Final transcription will use the recorded audio.") }
            return
        }
        pending.append(contentsOf: samples)
        let dispatch = !scheduled && pending.count >= chunkSize
        if dispatch { scheduled = true }
        lock.unlock()
        if dispatch { workQueue.async { [weak self] in self?.drain(id: id, token: token, finishing: false) } }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token && sessionID != nil
    }

    private func drain(id: String, token: UInt64, finishing: Bool) {
        while true {
            lock.lock()
            guard generation == token, sessionID == id else { lock.unlock(); return }
            guard pending.count >= chunkSize || (finishing && pending.count > 0) else {
                scheduled = false
                lock.unlock()
                return
            }
            let size = chunkSize
            var samples = pending.take(size)
            lock.unlock()
            if samples.count < size { samples.append(contentsOf: repeatElement(0, count: size - samples.count)) }
            do {
                let result = try bridge.feedStreamingChunk(sessionId: id, audioSamples: samples)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(token) else { return }
                    self.onUpdate?(result.committedText, result.tentativeText, result.newlyCommittedText)
                }
            } catch {
                fail(id: id, token: token, message: error.localizedDescription)
                return
            }
        }
    }

    func stop(completion: @escaping (String) -> Void = { _ in }) {
        lock.lock()
        accepting = false
        let id = sessionID
        let token = generation
        lock.unlock()
        guard let id else { completion(""); return }
        workQueue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.drain(id: id, token: token, finishing: true)
            guard self.isCurrent(token) else { return }
            let text = (try? self.bridge.finishStreamingSession(sessionId: id)) ?? ""
            self.lock.lock()
            if self.generation == token { self.sessionID = nil; self.pending.removeAll(); self.scheduled = false }
            self.lock.unlock()
            DispatchQueue.main.async {
                self.lock.lock(); let valid = self.generation == token; self.lock.unlock()
                if valid { completion(text) }
            }
        }
    }

    func cancel() {
        lock.lock()
        let id = sessionID
        generation &+= 1
        sessionID = nil
        accepting = false
        scheduled = false
        pending.removeAll()
        lock.unlock()
        if let id { workQueue.async { [bridge] in bridge.cancelStreamingSession(sessionId: id) } }
    }

    private func fail(id: String, token: UInt64, message: String) {
        lock.lock()
        guard generation == token else { lock.unlock(); return }
        accepting = false
        scheduled = false
        sessionID = nil
        pending.removeAll()
        lock.unlock()
        bridge.cancelStreamingSession(sessionId: id)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let valid = self.generation == token; self.lock.unlock()
            if valid { self.onError?(message) }
        }
    }
}
