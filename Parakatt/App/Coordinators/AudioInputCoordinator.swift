import Foundation

/// Microphone/input-device UI actions.
@MainActor
final class AudioInputCoordinator {
    func listInputDevices(environment: PlatformEnvironment) -> [(uid: String, name: String, isDefault: Bool)] {
        environment.listInputDevices()
    }

    func setInputDevice(uid: String?, capture: AudioCapturing?) {
        capture?.setInputDevice(uid: uid)
        NSLog("[Parakatt] Input device set to: %@", uid ?? "system default")
    }

    func startCapture(_ capture: AudioCapturing?) throws {
        try capture?.startCapture()
    }

    func stopCaptureAndPrewarm(_ capture: AudioCapturing?, prewarmWindowSecs: TimeInterval) {
        capture?.stopCapture()
        capture?.prewarm(windowSecs: prewarmWindowSecs)
    }
}
