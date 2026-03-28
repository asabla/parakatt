import Cocoa
import HotKey

/// Manages global hotkey: Option+Space to start, release Option to stop.
///
/// Press Option+Space to begin recording.
/// Keep holding Option (you can release Space).
/// Release Option to stop recording and transcribe.
class HotkeyService {
    private weak var appState: AppState?
    private var hotKey: HotKey?
    private var flagsMonitor: Any?
    private var isRecording = false

    init(appState: AppState) {
        self.appState = appState
        setupHotKey()
        setupFlagsMonitor()
    }

    deinit {
        hotKey = nil
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
    }

    private func setupHotKey() {
        // Option+Space triggers recording start
        hotKey = HotKey(key: .space, modifiers: [.option])

        hotKey?.keyDownHandler = { [weak self] in
            guard let self, !self.isRecording else { return }
            self.isRecording = true
            NSLog("[Parakatt] ▶ Option+Space — recording started")
            self.appState?.startRecording()
        }

        // Don't use keyUpHandler — Option release is detected via flagsChanged
    }

    private func setupFlagsMonitor() {
        // Detect Option key release to stop recording
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.isRecording else { return }

            // If Option is no longer held, stop recording
            if !event.modifierFlags.contains(.option) {
                self.isRecording = false
                NSLog("[Parakatt] ⏹ Option released — stopping recording")
                DispatchQueue.main.async {
                    self.appState?.stopRecording()
                }
            }
        }

        NSLog("[Parakatt] Hotkey: Option+Space to start, release Option to stop")
    }
}
