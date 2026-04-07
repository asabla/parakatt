import Cocoa
import ParakattCore
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var menuBarManager: MenuBarManager?
    private var hotkeyService: HotkeyService?
    private var permissionService: PermissionService?
    private var overlayController: RecordingOverlayController?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize the Rust core's logger BEFORE constructing anything
        // that may log. Without this, every `log::info!`/`warn!`/`error!`
        // inside parakatt-core is silently dropped — which is exactly how
        // issue #23 stayed invisible: the storage failures *were* logged,
        // but no Rust log subscriber was ever installed. Output goes to
        // stderr, which Console.app captures alongside our NSLog lines.
        ParakattCore.initLogging(defaultLevel: "info")

        permissionService = PermissionService()
        permissionService?.requestPermissionsIfNeeded()

        menuBarManager = MenuBarManager(appState: appState)
        overlayController = RecordingOverlayController(appState: appState)

        appState.initializeEngine()

        // Load hotkey config from engine and create the service
        let hotkeyConfig = appState.loadHotkeyConfig()
        hotkeyService = HotkeyService(
            appState: appState,
            key: hotkeyConfig.key,
            modifiers: hotkeyConfig.modifiers,
            mode: hotkeyConfig.mode
        )
        appState.hotkeyService = hotkeyService

        // Show onboarding on first launch, or Settings if model needed
        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if !hasOnboarded {
            showOnboarding()
        } else if appState.needsModelDownload {
            DispatchQueue.main.async {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    private func showOnboarding() {
        let view = OnboardingView {
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            // After onboarding, open Settings if model still needed
            if self.appState.needsModelDownload {
                DispatchQueue.main.async {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        }
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Parakatt"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
