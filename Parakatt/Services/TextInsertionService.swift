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

    /// Pending clipboard restore work item, captured so we can cancel
    /// it from `deinit` if the service is torn down before the timer
    /// fires (otherwise the closure outlives `self` and races on
    /// `savedItems`).
    private var pendingRestore: DispatchWorkItem?

    deinit {
        pendingRestore?.cancel()
        pendingRestore = nil
    }

    /// Insert text into the focused application. Returns false if all strategies fail.
    @discardableResult
    func insertText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let trusted = AXIsProcessTrusted()
        NSLog("[Parakatt] Inserting text (%d chars), AXIsProcessTrusted=%d", text.count, trusted)

        // Only attempt the AX path when we actually have permission;
        // otherwise it always fails after a noisy round-trip and we
        // skip straight to clipboard paste.
        if trusted, insertViaAccessibility(text) {
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
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else {
            NSLog("[Parakatt] AX Strategy: focused element is not an AXUIElement")
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
        usleep(10_000) // 10ms between keyDown/keyUp (was 30ms)
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
    /// changeCount captured right after we write our transcription to the clipboard.
    private var changeCountAfterSet: Int = 0

    private func setClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        savedItems = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type, data)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        changeCountAfterSet = pasteboard.changeCount
        usleep(20_000) // 20ms to ensure pasteboard is ready (was 50ms)
    }

    private func scheduleClipboardRestore() {
        let expectedCount = changeCountAfterSet
        let items = savedItems

        // Cancel any in-flight restore so we don't race two fires.
        pendingRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let pasteboard = NSPasteboard.general
            // Only restore if nothing else has touched the clipboard since we set it.
            if pasteboard.changeCount == expectedCount {
                pasteboard.clearContents()
                if let items = items {
                    for (type, data) in items {
                        pasteboard.setData(data, forType: type)
                    }
                }
            }
            self?.pendingRestore = nil
        }
        pendingRestore = work
        // 1.0s instead of 0.5s gives slow machines a more reliable
        // window before the user might manually copy something else.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
