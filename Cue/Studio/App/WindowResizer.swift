import AppKit
import ApplicationServices
import RecordKit

/// Puts another application's window at a preset size, through Accessibility.
///
/// The only way one app can move and size another's window on macOS, and it needs the
/// Accessibility grant — the same one recording keyboard shortcuts needs, asked for the same
/// way (`AccessibilityAccess`). Without it this says so and does nothing; it never puts up
/// the system's dialog by itself, because a dialog appearing from a menu item that was
/// supposed to resize a window is a surprise, and the picker has a button for the asking.
///
/// Everything that can be worked out without touching the window — where it should go,
/// which screen it is on, which of the app's windows it is — is `WindowSizing`'s, in
/// RecordKit, where it is tested. What is here is the part that cannot be: reading the
/// app's windows and setting one's position and size.
@MainActor
enum WindowResizer {
    /// Whether another app's window can be resized from here at all.
    ///
    /// Not while Cue Studio is sandboxed, as it ships: the App Sandbox does not let an app
    /// drive another app's windows through Accessibility, grant or no grant, so the menu
    /// would only ever end in "couldn't". The code is kept for a build that isn't sandboxed
    /// — or for doing the resize from a helper that is allowed to.
    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
    }

    enum Outcome: Equatable {
        /// The window is the size asked for — in points, and the pixels it will record at.
        case resized(points: CGSize, pixels: CGSize, isShrunk: Bool)
        /// The app would not let the window be that size — it has a smallest or a largest
        /// of its own — and this is the size it kept.
        case keptItsOwnSize(points: CGSize, pixels: CGSize)
        /// Cue Studio is not trusted with Accessibility.
        case needsAccess
        /// None of the app's windows is where the chosen window was: it has moved, closed,
        /// or is on a Space Accessibility cannot see.
        case windowNotFound
        /// The app refused, or the window server did.
        case failed
    }

    /// Resizes the window the recorder knows by `windowFrame` — `SCWindow.frame`, top-left
    /// points — belonging to `processID`, to `preset`.
    static func resize(processID: pid_t, windowFrame: CGRect, title: String?,
                       to preset: WindowSizePreset) -> Outcome {
        guard AccessibilityAccess.isGranted else { return .needsAccess }
        guard processID > 0, let main = NSScreen.screens.first else { return .failed }

        // The screen the window is on, and its usable area, in the top-left points the
        // window's frame is in.
        let mainHeight = main.frame.height
        let screens = NSScreen.screens
        let frames = screens.map { WindowSizing.topLeft($0.frame, mainHeight: mainHeight) }
        guard let index = WindowSizing.screen(for: windowFrame, among: frames) else { return .failed }
        let screen = screens[index]
        let scale = screen.backingScaleFactor
        guard let plan = WindowSizing.frame(for: preset, window: windowFrame,
                                            visibleFrame: WindowSizing.topLeft(screen.visibleFrame, mainHeight: mainHeight),
                                            backingScale: scale)
        else { return .failed }

        // The app's windows, and which of them is the one that was picked.
        let application = AXUIElementCreateApplication(processID)
        guard let windows = attribute(of: application, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty
        else { return .windowNotFound }
        let candidates = windows.map {
            WindowSizing.Candidate(frame: frame(of: $0) ?? .null, title: attribute(of: $0, kAXTitleAttribute) as? String)
        }
        guard let found = WindowSizing.match(windowFrame, title: title, among: candidates) else { return .windowNotFound }
        let window = windows[found]

        // Size, place, and size again. Growing a window near the edge of the screen is
        // refused by some apps until it has been moved, and moving it can be refused until
        // it is small enough to fit where it is going; asking for the size either side of
        // the move settles both in any order.
        let sized = set(window, size: plan.frame.size)
        let placed = set(window, origin: plan.frame.origin)
        let resized = set(window, size: plan.frame.size)
        guard sized || placed || resized else { return .failed }

        // What it actually became, which is the truth whatever was asked.
        guard let now = frame(of: window) else { return .failed }
        let pixels = CGSize(width: (now.width * scale).rounded(), height: (now.height * scale).rounded())
        if abs(now.width - plan.frame.width) > 1 || abs(now.height - plan.frame.height) > 1 {
            return .keptItsOwnSize(points: now.size, pixels: pixels)
        }
        return .resized(points: now.size, pixels: pixels, isShrunk: plan.isShrunk)
    }

    // MARK: - Accessibility

    private static func attribute(of element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// A window's frame in global top-left points. Position and size arrive as `AXValue`
    /// boxes rather than as numbers, which is why this is four calls instead of one.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(of: element, kAXPositionAttribute),
              let size = attribute(of: element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func set(_ window: AXUIElement, size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    private static func set(_ window: AXUIElement, origin: CGPoint) -> Bool {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }
}
