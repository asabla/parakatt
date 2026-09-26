import Foundation
import ParakattCore

/// Bounds queued work before it owns an audio array. Owners release after work finishes.
final class WorkCapacity {
    private let lock = NSLock()
    private var used = 0
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func reserve(_ amount: Int = 1) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard amount >= 0, amount <= limit - used else { return false }
        used += amount
        return true
    }
    func release(_ amount: Int = 1) { lock.lock(); used = max(0, used - amount); lock.unlock() }
}

/// Writes on its own queue, with at most two seconds of pending audio in memory.
/// Call finish from a worker after capture stops, before final session persistence.
final class CaptureJournal {
    private let queue = DispatchQueue(label: "Parakatt.capture-recovery", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let capacity = WorkCapacity(limit: 32_000)
    private let lock = NSLock()
    private var failed = false
    private let bridge: CoreBridge
    let id: String
    private let enabled: Bool
    private let onFailure: (String) -> Void
    init(bridge: CoreBridge, id: String, source: String, mode: String, onFailure: @escaping (String) -> Void) throws {
        self.bridge = bridge; self.id = id; self.onFailure = onFailure
        enabled = bridge.getRecoveryAudio()
        queue.setSpecific(key: queueKey, value: true)
        try bridge.beginCapture(id: id, source: source, mode: mode)
    }
    func append(_ samples: [Float], source: ChunkSource) {
        guard enabled, !samples.isEmpty else { return }
        lock.lock(); let stopped = failed; lock.unlock()
        guard !stopped else { return }
        guard capacity.reserve(samples.count) else { fail("Audio recovery could not keep up. Recording is incomplete."); return }
        queue.async { [self] in
            defer { capacity.release(samples.count) }
            do { try bridge.appendCaptureAudio(id: id, source: source, samples: samples) }
            catch { fail("Audio recovery failed. Recording is incomplete: \(error.localizedDescription)") }
        }
    }
    func markSpeechGap() { queue.async { [self] in try? bridge.markCaptureGap(id: id, audioLost: false) } }
    private func fail(_ message: String) {
        lock.lock(); let first = !failed; failed = true; lock.unlock()
        guard first else { return }
        if DispatchQueue.getSpecific(key: queueKey) == true {
            try? bridge.markCaptureGap(id: id, audioLost: true)
        } else {
            queue.async { [self] in try? bridge.markCaptureGap(id: id, audioLost: true) }
        }
        DispatchQueue.main.async { [onFailure] in onFailure(message) }
    }
    func finish() { queue.sync {}; bridge.endCapture(id: id) }
}
