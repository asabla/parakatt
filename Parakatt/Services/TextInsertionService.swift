import Cocoa
import ApplicationServices

/// Inserts transcribed text into the currently focused application.
///
/// Uses two strategies:
/// 1. Primary: AXUIElement API to set the focused text field's value
/// 2. Fallback: Copy to pasteboard and simulate Cmd+V
class TextInsertionService {
    /// Insert text into the currently focused text field.
    func insertText(_ text: String) {
        // Try the accessibility approach first
        if insertViaAccessibility(text) {
            return
        }

        // Fall back to clipboard + paste
        insertViaPaste(text)
    }

    // MARK: - Accessibility API approach

    /// Try to insert text directly via the Accessibility API.
    /// Returns true if successful.
    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        // Get the focused element
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard focusResult == .success,
              let element = focusedElement else {
            return false
        }

        // AXUIElement is a CFTypeRef — this cast is always valid when AX returns success
        let axElement = element as! AXUIElement // swiftlint:disable:this force_cast

        // Check if the element supports setting value
        var settable: DarwinBoolean = false
        let isSettable = AXUIElementIsAttributeSettable(
            axElement,
            kAXValueAttribute as CFString,
            &settable
        )

        guard isSettable == .success, settable.boolValue else {
            return false
        }

        // Try to get the current selected text range
        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        )

        if rangeResult == .success {
            // Replace selected text
            let setResult = AXUIElementSetAttributeValue(
                axElement,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            return setResult == .success
        }

        // Fall back to setting the entire value (appending)
        var currentValue: AnyObject?
        AXUIElementCopyAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            &currentValue
        )

        let newValue: String
        if let current = currentValue as? String {
            newValue = current + text
        } else {
            newValue = text
        }

        let result = AXUIElementSetAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            newValue as CFTypeRef
        )

        return result == .success
    }

    // MARK: - Clipboard + Paste approach

    /// Insert text by copying to clipboard and simulating Cmd+V.
    private func insertViaPaste(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents to restore later
        let previousContents = pasteboard.string(forType: .string)

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulateKeyPress(keyCode: 9, flags: .maskCommand) // 9 = 'v' key

        // Restore clipboard after a short delay
        if let previous = previousContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    // MARK: - Key simulation

    /// Simulate a key press event using CGEvent.
    private func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
