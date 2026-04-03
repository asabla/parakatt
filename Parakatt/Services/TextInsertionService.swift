import Cocoa
import Carbon

/// Inserts transcribed text into the currently focused application.
///
/// Strategy order:
/// 1. Try AXUIElement selectedText replacement (most native, no clipboard clobber)
/// 2. Fall back to clipboard paste via CGEvent Cmd+V
/// 3. Fall back to clipboard paste via AppleScript System Events
///
/// Logs which strategy was used for debugging.
class TextInsertionService {

    /// Insert text into the focused application. Returns false if all strategies fail.
    @discardableResult
    func insertText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        NSLog("[Parakatt] Inserting text (%d chars), AXIsProcessTrusted=%d", text.count, AXIsProcessTrusted())

        if insertViaAccessibility(text) {
            NSLog("[Parakatt] Text inserted via Accessibility API (%d chars)", text.count)
            return true
        }

        if insertViaPaste(text) {
            NSLog("[Parakatt] Text inserted via CGEvent paste (%d chars)", text.count)
            return true
        }

        if insertViaAppleScript(text) {
            NSLog("[Parakatt] Text inserted via AppleScript paste (%d chars)", text.count)
            return true
        }

        NSLog("[Parakatt] All text insertion strategies failed (%d chars)", text.count)
        return false
    }

    // MARK: - Strategy 1: Accessibility API

    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let copyResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard copyResult == .success, let element = focusedElement else {
            NSLog("[Parakatt] AX Strategy: no focused element (error=%d)", copyResult.rawValue)
            return false
        }

        let axElement = element as! AXUIElement

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            axElement,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            NSLog("[Parakatt] AX Strategy: selectedText not settable")
            return false
        }

        let result = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if result != .success {
            NSLog("[Parakatt] AX Strategy: setAttribute failed (error=%d)", result.rawValue)
        }
        return result == .success
    }

    // MARK: - Strategy 2: Clipboard + CGEvent Cmd+V

    private func insertViaPaste(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            NSLog("[Parakatt] CGEvent Strategy: failed to create event source")
            return false
        }

        let vKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            NSLog("[Parakatt] CGEvent Strategy: failed to create key events")
            return false
        }

        setClipboard(text)

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        usleep(30_000)
        keyUp.post(tap: .cgSessionEventTap)

        scheduleClipboardRestore()
        return true
    }

    // MARK: - Strategy 3: Clipboard + AppleScript System Events

    private func insertViaAppleScript(_ text: String) -> Bool {
        setClipboard(text)

        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error = error {
            NSLog("[Parakatt] AppleScript Strategy: failed - %@", error)
            return false
        }

        scheduleClipboardRestore()
        return true
    }

    // MARK: - Clipboard helpers

    private var savedItems: [(NSPasteboard.PasteboardType, Data)]?
    private var savedChangeCount: Int = 0

    private func setClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        savedChangeCount = pasteboard.changeCount
        savedItems = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type, data)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        usleep(50_000) // 50ms to ensure pasteboard is ready
    }

    private func scheduleClipboardRestore() {
        let expectedCount = savedChangeCount + 1
        let items = savedItems

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount == expectedCount {
                pasteboard.clearContents()
                if let items = items {
                    for (type, data) in items {
                        pasteboard.setData(data, forType: type)
                    }
                }
            }
        }
    }
}
