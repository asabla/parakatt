import Cocoa
import SwiftUI

/// Application delegate managing the app lifecycle,
/// menubar icon, and global services.
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var menuBarManager: MenuBarManager?
    private var hotkeyService: HotkeyService?
    private var permissionService: PermissionService?
    private var overlayController: RecordingOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check and request permissions
        permissionService = PermissionService()
        permissionService?.requestPermissionsIfNeeded()

        // Set up menubar
        menuBarManager = MenuBarManager(appState: appState)

        // Set up recording overlay
        overlayController = RecordingOverlayController(appState: appState)

        // Set up global hotkey
        hotkeyService = HotkeyService(appState: appState)

        // Initialize the Rust engine
        appState.initializeEngine()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
