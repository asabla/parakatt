import Foundation

/// Synchronizes value access, including compound mutations such as += and append.
@propertyWrapper
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var value: Value
    init(wrappedValue: Value) { value = wrappedValue }
    var wrappedValue: Value {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
        // swiftlint:disable:next unused_declaration // Swift calls this accessor for atomic compound mutations.
        _modify { lock.lock(); defer { lock.unlock() }; yield &value }
    }
}
