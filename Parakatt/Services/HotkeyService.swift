import Cocoa
import HotKey

/// Manages global hotkey for recording.
///
/// Supports two modes:
/// - **Hold**: Press key to start recording, release modifier to stop.
/// - **Toggle**: Press key to start recording, press again to stop.
class HotkeyService {
    private weak var appState: AppState?
    private var hotKey: HotKey?
    private var flagsMonitor: Any?
    private var isRecording = false

    private var configuredKey: Key
    private var configuredModifiers: NSEvent.ModifierFlags
    private var isToggleMode: Bool

    init(appState: AppState, key: Key = .space, modifiers: NSEvent.ModifierFlags = [.option], mode: String = "hold") {
        self.appState = appState
        self.configuredKey = key
        self.configuredModifiers = modifiers
        self.isToggleMode = mode == "toggle"
        setupHotKey()
        setupFlagsMonitor()
    }

    deinit {
        hotKey = nil
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
    }

    /// Reconfigure the hotkey at runtime (e.g. from settings).
    func reconfigure(key: Key, modifiers: NSEvent.ModifierFlags, mode: String) {
        hotKey = nil
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        flagsMonitor = nil
        isRecording = false

        configuredKey = key
        configuredModifiers = modifiers
        isToggleMode = mode == "toggle"

        setupHotKey()
        setupFlagsMonitor()

        NSLog("[Parakatt] Hotkey reconfigured: %@ + %@ (%@)",
              modifierSymbols(configuredModifiers), "\(configuredKey)", isToggleMode ? "toggle" : "hold")
    }

    private func setupHotKey() {
        hotKey = HotKey(key: configuredKey, modifiers: configuredModifiers)

        hotKey?.keyDownHandler = { [weak self] in
            guard let self else { return }

            if self.isToggleMode {
                // Toggle mode: press to start, press again to stop
                if self.isRecording {
                    self.isRecording = false
                    NSLog("[Parakatt] ⏹ Hotkey toggle — stopping recording")
                    DispatchQueue.main.async {
                        self.appState?.stopRecording()
                    }
                } else {
                    self.isRecording = true
                    NSLog("[Parakatt] ▶ Hotkey toggle — recording started")
                    DispatchQueue.main.async {
                        self.appState?.startRecording()
                    }
                }
            } else {
                // Hold mode: press to start, release modifier to stop
                guard !self.isRecording else { return }
                self.isRecording = true
                NSLog("[Parakatt] ▶ Hotkey hold — recording started")
                DispatchQueue.main.async {
                    self.appState?.startRecording()
                }
            }
        }
    }

    private func setupFlagsMonitor() {
        // Only needed for hold mode — detect modifier release to stop recording
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.isRecording, !self.isToggleMode else { return }

            // Check if configured modifier(s) are no longer held
            if !event.modifierFlags.contains(self.configuredModifiers) {
                self.isRecording = false
                NSLog("[Parakatt] ⏹ Modifier released — stopping recording")
                DispatchQueue.main.async {
                    self.appState?.stopRecording()
                }
            }
        }

        NSLog("[Parakatt] Hotkey: %@ + %@ (%@)",
              modifierSymbols(configuredModifiers), "\(configuredKey)", isToggleMode ? "toggle" : "hold")
    }

    // MARK: - Key/modifier string mapping

    /// Convert string config values to HotKey.Key.
    static func keyFromString(_ name: String) -> Key? {
        switch name.lowercased() {
        case "space": return .space
        case "tab": return .tab
        case "return", "enter": return .return
        case "escape", "esc": return .escape
        case "delete", "backspace": return .delete
        // Letters
        case "a": return .a; case "b": return .b; case "c": return .c; case "d": return .d
        case "e": return .e; case "f": return .f; case "g": return .g; case "h": return .h
        case "i": return .i; case "j": return .j; case "k": return .k; case "l": return .l
        case "m": return .m; case "n": return .n; case "o": return .o; case "p": return .p
        case "q": return .q; case "r": return .r; case "s": return .s; case "t": return .t
        case "u": return .u; case "v": return .v; case "w": return .w; case "x": return .x
        case "y": return .y; case "z": return .z
        // Numbers
        case "0": return .zero; case "1": return .one; case "2": return .two
        case "3": return .three; case "4": return .four; case "5": return .five
        case "6": return .six; case "7": return .seven; case "8": return .eight
        case "9": return .nine
        // Function keys
        case "f1": return .f1; case "f2": return .f2; case "f3": return .f3
        case "f4": return .f4; case "f5": return .f5; case "f6": return .f6
        case "f7": return .f7; case "f8": return .f8; case "f9": return .f9
        case "f10": return .f10; case "f11": return .f11; case "f12": return .f12
        default: return nil
        }
    }

    /// Convert string modifier names to NSEvent.ModifierFlags.
    static func modifiersFromStrings(_ names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "option", "alt": flags.insert(.option)
            case "command", "cmd": flags.insert(.command)
            case "control", "ctrl": flags.insert(.control)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        return flags
    }

    /// Convert Key to a config string.
    static func stringFromKey(_ key: Key) -> String {
        switch key {
        case .space: return "space"
        case .tab: return "tab"
        case .return: return "return"
        case .escape: return "escape"
        case .delete: return "delete"
        case .a: return "a"; case .b: return "b"; case .c: return "c"; case .d: return "d"
        case .e: return "e"; case .f: return "f"; case .g: return "g"; case .h: return "h"
        case .i: return "i"; case .j: return "j"; case .k: return "k"; case .l: return "l"
        case .m: return "m"; case .n: return "n"; case .o: return "o"; case .p: return "p"
        case .q: return "q"; case .r: return "r"; case .s: return "s"; case .t: return "t"
        case .u: return "u"; case .v: return "v"; case .w: return "w"; case .x: return "x"
        case .y: return "y"; case .z: return "z"
        case .zero: return "0"; case .one: return "1"; case .two: return "2"
        case .three: return "3"; case .four: return "4"; case .five: return "5"
        case .six: return "6"; case .seven: return "7"; case .eight: return "8"
        case .nine: return "9"
        case .f1: return "f1"; case .f2: return "f2"; case .f3: return "f3"
        case .f4: return "f4"; case .f5: return "f5"; case .f6: return "f6"
        case .f7: return "f7"; case .f8: return "f8"; case .f9: return "f9"
        case .f10: return "f10"; case .f11: return "f11"; case .f12: return "f12"
        default: return "space"
        }
    }

    /// Convert NSEvent.ModifierFlags to string array.
    static func stringsFromModifiers(_ flags: NSEvent.ModifierFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.command) { result.append("command") }
        if flags.contains(.option) { result.append("option") }
        if flags.contains(.control) { result.append("control") }
        if flags.contains(.shift) { result.append("shift") }
        return result
    }

    /// Human-readable modifier symbols for display.
    private func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    /// Human-readable display name for a Key.
    static func displayName(for key: Key) -> String {
        switch key {
        case .space: return "Space"
        case .tab: return "Tab"
        case .return: return "Return"
        case .escape: return "Esc"
        case .delete: return "Delete"
        default:
            let str = stringFromKey(key)
            return str.count == 1 ? str.uppercased() : str.capitalized
        }
    }

    /// Human-readable modifier display names.
    static func modifierDisplayNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃ Control") }
        if flags.contains(.option) { parts.append("⌥ Option") }
        if flags.contains(.shift) { parts.append("⇧ Shift") }
        if flags.contains(.command) { parts.append("⌘ Command") }
        return parts
    }
}
