import Foundation

/// User-visible notification actions.
@MainActor
final class NotificationCoordinator {
    func requestAuthorization(environment: PlatformEnvironment) {
        environment.notifications.requestAuthorization()
    }

    func sendTranscriptionReady(environment: PlatformEnvironment, preview: String, source: String) {
        environment.notifications.sendTranscriptionReady(preview: preview, source: source)
    }
}
