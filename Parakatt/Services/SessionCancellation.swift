import Foundation

/// Makes cancellation before session creation and cancellation during processing equivalent.
final class SessionCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (() -> Void)?

    func start(_ create: () throws -> Void, onCancel: @escaping () -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        try create()
        action = onCancel
        return true
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let callback = action
        action = nil
        lock.unlock()
        callback?()
    }
    func finish() {
        lock.lock()
        action = nil
        lock.unlock()
    }
}
