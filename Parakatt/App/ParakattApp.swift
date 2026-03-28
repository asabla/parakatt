import SwiftUI

/// Parakatt — macOS voice-to-text application.
///
/// Runs as a menubar-only app (no dock icon).
/// LSUIElement = YES in Info.plist hides the dock icon.
@main
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
