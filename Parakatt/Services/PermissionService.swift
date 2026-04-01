import Cocoa

/// Manages permission requests.
///
/// Accessibility is needed for text insertion into other apps.
/// Microphone permission is requested automatically by AVAudioEngine.
/// System Audio Recording is handled by Core Audio taps (permission prompt
/// is triggered automatically on first tap creation).
class PermissionService {
    private static let accessibilityPromptedKey = "accessibilityPrompted"
    private static let lastKnownVersionKey = "lastKnownAppVersion"

    func requestPermissionsIfNeeded() {
        handlePostUpdateRecovery()
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

    /// Detects app version changes and resets the prompt flag so the system
    /// accessibility dialog can fire again. Also opens the relevant System
    /// Settings pane to guide the user.
    private func handlePostUpdateRecovery() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let lastVersion = UserDefaults.standard.string(forKey: Self.lastKnownVersionKey)

        defer {
            UserDefaults.standard.set(currentVersion, forKey: Self.lastKnownVersionKey)
        }

        guard let lastVersion, lastVersion != currentVersion else { return }

        NSLog("[Parakatt] App updated from %@ to %@ — checking permissions", lastVersion, currentVersion)

        if !AXIsProcessTrusted() {
            NSLog("[Parakatt] Accessibility lost after update — resetting prompt flag and opening Settings")
            // Reset so the system prompt fires again
            UserDefaults.standard.set(false, forKey: Self.accessibilityPromptedKey)
            // Open the Accessibility settings pane directly
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
