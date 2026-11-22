import Cocoa
import AVFoundation

/// Reads live permission state. Starting a recording owns the microphone and system audio prompts.
@MainActor
enum PermissionService {
    struct Status {
        let accessibilityTrusted: Bool
        let microphone: AVAuthorizationStatus

        var microphoneGranted: Bool { microphone == .authorized }

        var microphoneTitle: String {
            switch microphone {
            case .authorized: "Granted"
            case .notDetermined: "Ask on first recording"
            case .denied: "Denied"
            case .restricted: "Restricted"
            @unknown default: "Unknown"
            }
        }
    }

    static func status() -> Status {
        Status(
            accessibilityTrusted: AXIsProcessTrusted(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio)
        )
    }

    static func logStatus() {
        let current = status()
        NSLog("[Parakatt] Permissions at startup: Microphone=%@, Accessibility=%@, event posting=%@",
              MicrophoneAuthorization.description(current.microphone),
              current.accessibilityTrusted ? "granted" : "not granted",
              CGPreflightPostEventAccess() ? "allowed" : "not allowed")
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
