import Cocoa
import Foundation
import UserNotifications

final class MacAppEnvironment: PlatformEnvironment {
    let paths: AppPathProviding = MacPathProvider()
    let secrets: SecretStoring = MacSecretStore()
    let notifications: NotificationSending = MacNotificationSender()
    let permissions: PermissionManaging = PermissionService()
    let runningApps: RunningAppProviding = MacRunningAppProvider()

    func makeAudioCapture() -> AudioCapturing {
        AudioCaptureService()
    }

    func listInputDevices() -> [(uid: String, name: String, isDefault: Bool)] {
        AudioCaptureService.listInputDevices()
    }

    func makeTextInserter() -> TextInserting {
        TextInsertionService()
    }

    func makeContextProvider() -> AppContextProviding {
        ContextService()
    }

    @available(macOS 14.2, *)
    func makeSystemAudioCapture() -> SystemAudioCapturing {
        SystemAudioCaptureService()
    }
}

private final class MacPathProvider: AppPathProviding {
    var modelsDirectory: URL {
        let dir = appSupportDirectory().appendingPathComponent("Parakatt/models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var configDirectory: URL {
        let dir = appSupportDirectory().appendingPathComponent("Parakatt/config")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func appSupportDirectory() -> URL {
        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support")
    }
}

final class MacSecretStore: SecretStoring {
    func set(_ value: String, forKey key: String) {
        KeychainService.set(value, forKey: key)
    }

    func get(_ key: String) -> String? {
        KeychainService.get(key)
    }

    func delete(_ key: String) {
        KeychainService.delete(key)
    }
}

private final class MacNotificationSender: NotificationSending {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("[Parakatt] Notification permission error: %@", error.localizedDescription)
            } else {
                NSLog("[Parakatt] Notification permission granted: %d", granted)
            }
        }
    }

    func sendTranscriptionReady(preview: String, source: String) {
        let content = UNMutableNotificationContent()
        content.title = source == "meeting" ? "Meeting transcription ready" : "Transcription complete"
        content.body = String(preview.prefix(100))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[Parakatt] Failed to send notification: %@", error.localizedDescription)
            }
        }
    }
}

private final class MacRunningAppProvider: RunningAppProviding {
    func listRunningAudioApps() -> [AudioSourceApp] {
        AudioSourceService.listRunningAudioApps()
    }

    func pidForBundleId(_ bundleId: String) -> pid_t? {
        AudioSourceService.pidForBundleId(bundleId)
    }

    func nameForBundleId(_ bundleId: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first(where: { !$0.isTerminated })?
            .localizedName
    }
}

extension AudioCaptureService: AudioCapturing {}

@available(macOS 14.2, *)
extension SystemAudioCaptureService: SystemAudioCapturing {}

extension TextInsertionService: TextInserting {}

extension ContextService: AppContextProviding {}
