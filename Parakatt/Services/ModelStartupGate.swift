import Foundation

/// Retain completion work while the final model loads, without blocking recording.
@MainActor
final class ModelStartupGate {
    enum State { case loading, ready, failed(String) }
    private var state: State = .failed("Download and load a transcription model in Settings.")
    private var waiting: [(String?) -> Void] = []

    func update(_ state: State) {
        self.state = state
        if case .loading = state { return }
        let callbacks = waiting
        waiting.removeAll()
        for callback in callbacks { whenReady(callback) }
    }

    /// A nil error means the final model is ready. Callers reject stale recordings.
    func whenReady(_ completion: @escaping (String?) -> Void) {
        switch state {
        case .loading: waiting.append(completion)
        case .ready: completion(nil)
        case .failed(let message): completion(message)
        }
    }
}
