import SwiftUI

/// The SwiftUI scene for the menu bar app.
///
/// The app executable calls `parakatt_main` to start this scene.
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
