import Cocoa
import Carbon

enum TextInsertionResult: Equatable {
    case empty
    case inserted
    case pasteRequested
    case permissionRequired
    case unavailable

    var recoveryMessage: String? {
        switch self {
        case .empty, .inserted, .pasteRequested: nil
        case .permissionRequired:
            "Recording saved. Enable Accessibility in System Settings to paste automatically, or copy from History."
        case .unavailable:
            "Recording saved. Copy the transcript from History to paste it."
        }
    }
}

@MainActor
final class TextInsertionService {
    struct Actions {
        let isAccessibilityTrusted: @MainActor () -> Bool
        let replaceSelection: @MainActor (String) -> Bool
        let canPostEvents: @MainActor () -> Bool
        let makePasteRequest: @MainActor () -> (@MainActor () -> Void)?
    }

    private let clipboard: ClipboardTransaction
    private let actions: Actions

    init(clipboard: ClipboardTransaction = ClipboardTransaction(), actions: Actions? = nil) {
        self.clipboard = clipboard
        self.actions = actions ?? Actions(
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            replaceSelection: Self.insertViaAccessibility,
            canPostEvents: { CGPreflightPostEventAccess() },
            makePasteRequest: Self.makePasteRequest
        )
    }

    func insertText(_ text: String) -> TextInsertionResult {
        guard !text.isEmpty else { return .empty }
        if actions.isAccessibilityTrusted(), actions.replaceSelection(text) {
            NSLog("[Parakatt] Text inserted via Accessibility API (%d chars)", text.count)
            return .inserted
        }
        guard actions.canPostEvents() else {
            NSLog("[Parakatt] Paste unavailable: event posting permission is missing")
            return .permissionRequired
        }
        guard let post = actions.makePasteRequest(), clipboard.set(text) else {
            NSLog("[Parakatt] Paste unavailable: could not prepare Cmd+V or write to clipboard")
            return .unavailable
        }
        post()
        clipboard.scheduleRestore()
        // Core Graphics does not confirm whether the target accepted Cmd+V.
        NSLog("[Parakatt] Paste requested via CGEvent (%d chars)", text.count)
        return .pasteRequested
    }

    // MARK: - Strategy 1: Accessibility API

    private static func insertViaAccessibility(_ text: String) -> Bool {
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

    private static func makePasteRequest() -> (@MainActor () -> Void)? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        let vKeyCode = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return nil
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        return {
            keyDown.post(tap: .cgSessionEventTap)
            usleep(10_000)
            keyUp.post(tap: .cgSessionEventTap)
        }
    }
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

    @discardableResult
    func set(_ text: String) -> Bool {
        pendingRestore?.cancel()
        // Consecutive insertions still restore the clipboard from before the first one.
        if expectedChange != pasteboard.changeCount {
            savedItems = pasteboard.pasteboardItems?.map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            } ?? []
        }
        pasteboard.clearContents()
        let written = pasteboard.setString(text, forType: .string)
        expectedChange = pasteboard.changeCount
        if !written { restore() }
        return written
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
