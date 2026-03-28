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

        // Try to get selected text and window title via Accessibility API
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
           let axApp = focusedApp as! AXUIElement? {

            // Window title
            var focusedWindow: AnyObject?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let axWindow = focusedWindow as! AXUIElement? {
                var title: AnyObject?
                if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &title) == .success,
                   let titleStr = title as? String {
                    context.windowTitle = titleStr
                }
            }
        }

        // Selected text from focused element
        var focusedElement: AnyObject?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
           let axElement = focusedElement as! AXUIElement? {
            var selectedText: AnyObject?
            if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
               let text = selectedText as? String, !text.isEmpty {
                context.selectedText = text
            }
        }

        return context
    }
}
