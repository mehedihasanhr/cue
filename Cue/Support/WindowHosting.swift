import AppKit
import SwiftUI

/// A window controller that hosts a SwiftUI root view in a plain `NSWindow`.
/// Used for every programmatically opened window (onboarding, preview, later the editor).
final class HostedWindowController: NSWindowController, NSWindowDelegate {
    /// Called once when the window closes. Owners use it to drop their reference.
    var onClose: (() -> Void)?

    init(
        title: String,
        contentSize: CGSize,
        styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable],
        rootView: some View
    ) {
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = styleMask
        window.setContentSize(contentSize)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Brings the window to the front. Agent apps (no Dock icon) must activate
    /// explicitly, otherwise the window opens behind the current app.
    /// Opens in front of every other app's windows and takes focus, however Cue
    /// was asked (the island, the menu bar, a hotkey — none of which activate it).
    func present() {
        showWindow(nil)
        guard let window else { return }
        NSApp.present(window)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
