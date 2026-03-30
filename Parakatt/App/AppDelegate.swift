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

        // If no model is downloaded, open Settings so user can download one
        if appState.needsModelDownload {
            DispatchQueue.main.async {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
