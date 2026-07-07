import Foundation

/// Microphone/input-device UI actions.
@MainActor
final class AudioInputCoordinator {
    private var capture: AudioCapturing?

    func configure(capture: AudioCapturing?) {
        self.capture = capture
    }

    func listInputDevices(environment: PlatformEnvironment) -> [(uid: String, name: String, isDefault: Bool)] {
        environment.listInputDevices()
    }

    func setInputDevice(uid: String?) {
        capture?.setInputDevice(uid: uid)
        NSLog("[Parakatt] Input device set to: %@", uid ?? "system default")
    }

    func startCapture() throws {
        try capture?.startCapture()
    }

    func stopCaptureAndPrewarm(prewarmWindowSecs: TimeInterval) {
        capture?.stopCapture()
        capture?.prewarm(windowSecs: prewarmWindowSecs)
    }
}
