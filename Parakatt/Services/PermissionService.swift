import Cocoa

/// Manages permission requests.
///
/// Accessibility is needed for text insertion into other apps.
/// Microphone permission is requested automatically by AVAudioEngine.
class PermissionService {
    private static let accessibilityPromptedKey = "accessibilityPrompted"

    func requestPermissionsIfNeeded() {
        checkAccessibilityPermission()
    }

    private func checkAccessibilityPermission() {
        if AXIsProcessTrusted() {
            NSLog("[Parakatt] Accessibility: granted")
            return
        }

        let alreadyPrompted = UserDefaults.standard.bool(forKey: Self.accessibilityPromptedKey)
        if !alreadyPrompted {
            NSLog("[Parakatt] Accessibility: prompting user...")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            UserDefaults.standard.set(true, forKey: Self.accessibilityPromptedKey)
        } else {
            NSLog("[Parakatt] Accessibility: not granted (user must enable in System Settings)")
        }
    }
}
