import Cocoa
import HotKey

/// Manages global hotkey for recording.
///
/// Supports two modes:
/// - **Hold**: Press key to start recording, release modifier to stop.
/// - **Toggle**: Press key to start recording, press again to stop.
@MainActor
protocol HotkeyRecording: AnyObject {
    var isRecording: Bool { get }
    var hotkeyRecordingID: UUID? { get }
    func startRecording()
    func stopRecording()
}

@MainActor
final class HotkeyService {
    private weak var appState: (any HotkeyRecording)?
    private var hotKey: HotKey?
    private var flagsMonitor: EventMonitorToken?
    private var localFlagsMonitor: EventMonitorToken?
    private var holdRecordingID: UUID?
    private let registerEvents: Bool
    private var configuredKey: Key
    private var configuredModifiers: NSEvent.ModifierFlags
    private var isToggleMode: Bool

    init(appState: any HotkeyRecording, key: Key = .space, modifiers: NSEvent.ModifierFlags = [.option], mode: String = "hold", registerEvents: Bool = true) {
        self.appState = appState
        self.configuredKey = key
        self.configuredModifiers = modifiers
        self.isToggleMode = mode == "toggle"
        self.registerEvents = registerEvents
        setupEvents()
    }

    func reconfigure(key: Key, modifiers: NSEvent.ModifierFlags, mode: String) {
        hotKey = nil
        flagsMonitor = nil
        localFlagsMonitor = nil
        if let holdRecordingID, appState?.hotkeyRecordingID == holdRecordingID { appState?.stopRecording() }
        holdRecordingID = nil
        configuredKey = key
        configuredModifiers = modifiers
        isToggleMode = mode == "toggle"
        setupEvents()
    }

    func handleKeyDown() {
        guard let appState else { return }
        if isToggleMode {
            if appState.isRecording { appState.stopRecording() }
            else { appState.startRecording() }
        } else if !appState.isRecording {
            appState.startRecording()
            holdRecordingID = appState.hotkeyRecordingID
        }
    }

    func handleModifierChange(_ modifiers: NSEvent.ModifierFlags) {
        guard !isToggleMode, let id = holdRecordingID, !modifiers.contains(configuredModifiers) else { return }
        holdRecordingID = nil
        if appState?.hotkeyRecordingID == id { appState?.stopRecording() }
    }

    nonisolated func enqueueKeyDown() {
        DispatchQueue.main.async { [weak self] in self?.handleKeyDown() }
    }

    nonisolated func enqueueModifierChange(_ modifiers: NSEvent.ModifierFlags) {
        DispatchQueue.main.async { [weak self] in self?.handleModifierChange(modifiers) }
    }

    private func setupEvents() {
        guard registerEvents else { return }
        hotKey = HotKey(key: configuredKey, modifiers: configuredModifiers)
        hotKey?.keyDownHandler = { [weak self] in
            self?.enqueueKeyDown()
        }
        flagsMonitor = EventMonitorToken(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.enqueueModifierChange(event.modifierFlags)
        })
        localFlagsMonitor = EventMonitorToken(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Queue local releases behind pending key-down events, as with global releases.
            self?.enqueueModifierChange(event.modifierFlags)
            return event
        })
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

}

/// An immutable AppKit registration token. It is only returned to removeMonitor.
/// AppKit permits removing the registration when its owner is released.
final class EventMonitorToken: @unchecked Sendable {
    private let token: Any
    init?(_ token: Any?) {
        guard let token else { return nil }
        self.token = token
    }
    deinit { NSEvent.removeMonitor(token) }
}
