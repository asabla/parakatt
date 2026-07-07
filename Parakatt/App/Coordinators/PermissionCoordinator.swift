import Foundation

/// User-facing permission prompts.
@MainActor
final class PermissionCoordinator {
    func promptForSystemAudioPermission(environment: PlatformEnvironment) {
        environment.permissions.promptForSystemAudioPermission()
    }
}
