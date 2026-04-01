import SwiftUI

/// Parakatt — macOS voice-to-text application.
///
/// Runs as a menubar-only app (no dock icon).
/// LSUIElement = YES in Info.plist hides the dock icon.
/// Parakatt SwiftUI app.
///
/// Note: @main is intentionally absent — the app is launched via the
/// parakatt_main() entry point in EntryPoint.swift, which is called
/// by the stable launcher binary. This keeps the launcher's CDHash
/// unchanged across versions so TCC permissions persist.
struct ParakattApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window, opened from the menubar
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}
