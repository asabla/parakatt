import Cocoa
import ApplicationServices

/// Reads context about the currently focused application.
///
/// This context is passed to the Rust engine for:
/// - Context-aware dictionary replacements
/// - LLM context in AI-enhanced modes
/// - Auto-activation rules
struct AppContextInfo {
    var appBundleId: String?
    var appName: String?
    var selectedText: String?
    var windowTitle: String?
}

class ContextService {
    /// Capture the current application context.
    func currentContext() -> AppContextInfo {
        var context = AppContextInfo()

        // Get the frontmost application
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            context.appBundleId = frontApp.bundleIdentifier
            context.appName = frontApp.localizedName
        }

        // Try to get selected text and window title via Accessibility API.
        // All AnyObject → AXUIElement bridges go through `axElement(_:)` which
        // verifies the CF type ID and returns nil on mismatch — no force-casts.
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
           let axAppElement = axElement(focusedApp) {

            // Window title
            var focusedWindow: AnyObject?
            if AXUIElementCopyAttributeValue(axAppElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let axWindowElement = axElement(focusedWindow) {
                var title: AnyObject?
                if AXUIElementCopyAttributeValue(axWindowElement, kAXTitleAttribute as CFString, &title) == .success,
                   let titleStr = title as? String {
                    context.windowTitle = titleStr
                }
            }
        }

        // Selected text from focused element
        var focusedElement: AnyObject?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
           let axElementRef = axElement(focusedElement) {
            var selectedText: AnyObject?
            if AXUIElementCopyAttributeValue(axElementRef, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
               let text = selectedText as? String, !text.isEmpty {
                context.selectedText = text
            }
        }

        return context
    }

    /// Safely bridge an AnyObject pulled out of the Accessibility API to
    /// `AXUIElement` after checking the CF type ID. Returns nil instead
    /// of force-casting when the value isn't an AXUIElement (which
    /// would otherwise crash on a programmer error).
    private func axElement(_ obj: AnyObject?) -> AXUIElement? {
        guard let obj, CFGetTypeID(obj) == AXUIElementGetTypeID() else { return nil }
        return (obj as! AXUIElement)
    }
}
