import Foundation

/// Timers created here are attached to the main run loop.
@MainActor
enum MainActorTimer {
    static func scheduledTimer(withTimeInterval interval: TimeInterval, repeats: Bool,
                               block: @escaping @MainActor @Sendable () -> Void) -> Timer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { block() }
        }
    }
}
