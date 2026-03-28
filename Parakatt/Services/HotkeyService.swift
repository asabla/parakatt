import Cocoa

/// Placeholder for future hotkey support.
/// Currently recording is triggered via the menubar icon.
///
/// TODO: Integrate KeyboardShortcuts package (sindresorhus)
/// for reliable, user-configurable global hotkeys.
class HotkeyService {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        NSLog("[Parakatt] Hotkey service: recording via menubar click (hotkeys TODO)")
    }
}
