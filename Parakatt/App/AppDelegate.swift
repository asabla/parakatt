import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var menuBarManager: MenuBarManager?
    private var hotkeyService: HotkeyService?
    private var permissionService: PermissionService?
    private var overlayController: RecordingOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        permissionService = PermissionService()
        permissionService?.requestPermissionsIfNeeded()

        menuBarManager = MenuBarManager(appState: appState)
        overlayController = RecordingOverlayController(appState: appState)
        hotkeyService = HotkeyService(appState: appState)

        appState.initializeEngine()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
