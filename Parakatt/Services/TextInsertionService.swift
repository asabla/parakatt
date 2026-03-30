import Cocoa
import Carbon

/// Inserts transcribed text into the currently focused application.
///
/// Strategy order:
/// 1. Try AXUIElement selectedText replacement (most native, no clipboard clobber)
/// 2. Fall back to clipboard paste via Cmd+V (works everywhere)
///
/// Logs which strategy was used for debugging.
class TextInsertionService {

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }

        if insertViaAccessibility(text) {
            NSLog("[Parakatt] Text inserted via Accessibility API (%d chars)", text.count)
            return
        }

        insertViaPaste(text)
        NSLog("[Parakatt] Text inserted via clipboard paste (%d chars)", text.count)
    }

    // MARK: - Strategy 1: Accessibility API

    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success, let element = focusedElement else {
            return false
        }

        let axElement = element as! AXUIElement

        // Check if the element has a selected text attribute we can set
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            axElement,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return false
        }

        // Set the selected text (replaces selection, or inserts at cursor if no selection)
        let result = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        return result == .success
    }

    // MARK: - Strategy 2: Clipboard + Cmd+V paste

    private func insertViaPaste(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let savedChangeCount = pasteboard.changeCount
        let previousItems = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type, data)
        }

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure pasteboard is ready
        usleep(50_000) // 50ms

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after paste completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Only restore if nothing else changed the clipboard
            if pasteboard.changeCount == savedChangeCount + 1 {
                pasteboard.clearContents()
                if let items = previousItems {
                    for (type, data) in items {
                        pasteboard.setData(data, forType: type)
                    }
                }
            }
        }
    }

    private func simulatePaste() {
        // Use CGEvent to simulate Cmd+V
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            NSLog("[Parakatt] Failed to create CGEventSource for paste")
            return
        }

        let vKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            NSLog("[Parakatt] Failed to create CGEvent for paste")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(30_000) // 30ms between down and up
        keyUp.post(tap: .cghidEventTap)
    }
}
