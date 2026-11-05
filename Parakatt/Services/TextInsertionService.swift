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
@MainActor
final class TextInsertionService {

    private let clipboard = ClipboardTransaction()

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
        // Force-cast safe: type ID verified immediately above.
        // swiftlint:disable:next force_cast // CF type ID is checked above.
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

    private func setClipboard(_ text: String) { clipboard.set(text) }
    private func scheduleClipboardRestore() { clipboard.scheduleRestore() }
}

/// Preserves every representation and item without replacing a later user copy.
@MainActor
final class ClipboardTransaction {
    private let pasteboard: NSPasteboard
    private var savedItems: [[(NSPasteboard.PasteboardType, Data)]]?
    private var expectedChange: Int?
    private var pendingRestore: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    deinit { pendingRestore?.cancel() }

    func set(_ text: String) {
        pendingRestore?.cancel()
        // Consecutive insertions still restore the clipboard from before the first one.
        if expectedChange != pasteboard.changeCount {
            savedItems = pasteboard.pasteboardItems?.map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            } ?? []
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        expectedChange = pasteboard.changeCount
    }

    func restore() {
        pendingRestore?.cancel()
        pendingRestore = nil
        defer { expectedChange = nil; savedItems = nil }
        guard expectedChange == pasteboard.changeCount, let savedItems else { return }
        let items = savedItems.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    func scheduleRestore() {
        pendingRestore?.cancel()
        pendingRestore = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return }
            self?.restore()
        }
    }
}
