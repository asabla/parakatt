import Foundation

protocol AppPathProviding {
    var modelsDirectory: URL { get }
    var configDirectory: URL { get }
}

protocol SecretStoring {
    func set(_ value: String, forKey key: String)
    func get(_ key: String) -> String?
    func delete(_ key: String)
}

protocol NotificationSending {
    func requestAuthorization()
    func sendTranscriptionReady(preview: String, source: String)
}

protocol PermissionManaging {
    func requestPermissionsIfNeeded()
    func promptForSystemAudioPermission()
}

protocol AudioCapturing: AnyObject {
    var onAudioSamples: (([Float]) -> Void)? { get set }
    var onDeviceChanged: (() -> Void)? { get set }

    func startCapture() throws
    func stopCapture()
    func prewarm(windowSecs: TimeInterval?)
    func setInputDevice(uid: String?)
}

protocol SystemAudioCapturing: AnyObject {
    var onAudioSamples: (([Float]) -> Void)? { get set }
    var onHealth: ((SystemAudioHealth) -> Void)? { get set }

    func startCapture(processID: pid_t?) throws
    func stopCapture()
}

protocol TextInserting {
    @discardableResult
    func insertText(_ text: String) -> Bool
}

protocol AppContextProviding {
    func currentContext() -> AppContextInfo
}

protocol RunningAppProviding {
    func listRunningAudioApps() -> [AudioSourceApp]
    func pidForBundleId(_ bundleId: String) -> pid_t?
    func nameForBundleId(_ bundleId: String) -> String?
}

protocol PlatformEnvironment {
    var paths: AppPathProviding { get }
    var secrets: SecretStoring { get }
    var notifications: NotificationSending { get }
    var permissions: PermissionManaging { get }
    var runningApps: RunningAppProviding { get }

    func makeAudioCapture() -> AudioCapturing
    func listInputDevices() -> [(uid: String, name: String, isDefault: Bool)]
    func makeTextInserter() -> TextInserting
    func makeContextProvider() -> AppContextProviding

    @available(macOS 14.2, *)
    func makeSystemAudioCapture() -> SystemAudioCapturing
}
