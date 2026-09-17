import AppKit
import ApplicationServices

/// Where the cursor was before Klik took activation for one of its panels: the app
/// in front and, with Accessibility access, the very element that had keyboard
/// focus. Handing activation back is not always enough for the field to take the
/// focus again (some apps leave it on the window); focusing the element explicitly
/// is what lets a paste — Klik's own ⌘V or the user's — land where the cursor was.
struct FrontField {
    let app: NSRunningApplication?
    let element: AXUIElement?

    /// Whether there is another app to go back to at all.
    var isOtherApp: Bool { app != nil && app != .current }

    /// The front app and its focused element, taken before Klik activates.
    static func capture() -> FrontField {
        let app = NSWorkspace.shared.frontmostApplication
        guard let app, app != .current, PermissionManager.hasAccessibilityAccess else {
            return FrontField(app: app, element: nil)
        }
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return FrontField(app: app, element: nil)
        }
        return FrontField(app: app, element: (focused as! AXUIElement))
    }

    /// Hands activation back to the app, gives the element its focus again once the
    /// app is in front, then runs `action` (a beat later, for the focus to settle).
    func restore(then action: @escaping @MainActor () -> Void = {}) {
        guard let app, isOtherApp else { action(); return }
        ClipboardHistory.activate(app)
        ClipboardHistory.whenFrontmost(app) {
            focusElement()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: action)
        }
    }

    private func focusElement() {
        guard let element else { return }
        // The element's window first, so the focus goes to a window that is in front.
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success, let window,
           CFGetTypeID(window) == AXUIElementGetTypeID() {
            AXUIElementSetAttributeValue(window as! AXUIElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
}
