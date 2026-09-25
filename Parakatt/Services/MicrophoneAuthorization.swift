import AVFoundation
import Foundation

/// Check permission before starting an engine. Never record while a prompt is pending.
enum MicrophoneAuthorization {
    static func description(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .notDetermined: return "not determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    static func requireAccess(
        status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio),
        request: () -> Void = {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                NSLog("[Parakatt] Microphone permission response: %@. Start recording again to continue.", granted ? "granted" : "denied")
            }
        }
    ) throws {
        NSLog("[Parakatt] Microphone authorization: %@", description(status))
        switch status {
        case .authorized: return
        case .notDetermined:
            request()
            throw AccessError.pending
        case .denied: throw AccessError.denied
        case .restricted: throw AccessError.restricted
        @unknown default: throw AccessError.restricted
        }
    }

    enum AccessError: Error, LocalizedError {
        case pending, denied, restricted
        var errorDescription: String? {
            switch self {
            case .pending: return "Allow microphone access in the macOS prompt, then start recording again."
            case .denied: return "Microphone access is denied. Enable Parakatt in System Settings > Privacy & Security > Microphone, then restart Parakatt."
            case .restricted: return "Microphone access is restricted by macOS. Check the device's privacy restrictions."
            }
        }
    }
}
