import AppKit
import SwiftUI

/// The Settings window: a sidebar of pages (searchable, an icon tile each) and
/// the chosen page on the right — the layout of System Settings and Raycast.
/// The title bar is transparent so the sidebar runs to the top, under the
/// traffic lights; the window remembers its size and the last page.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let navigation = SettingsNavigation()

    init(model: AppModel, shortcuts: ShortcutController, library: CaptureLibrary, clipboard: ClipboardHistory, preferences: AppPreferences, clock: PrayerClock? = nil, share: ShareSettings? = nil, sync: SyncFolder? = nil) {
        let root = SettingsRootView()
            .environment(navigation)
            .environment(model)
            .environment(shortcuts)
            .environment(library)
            .environment(clipboard)
            .environment(preferences)
            .environment(clock)
            .environment(share)
            .environment(sync)
            .frame(minWidth: 820, minHeight: 540)

        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Klik Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty toolbar only makes the title bar taller, so the traffic lights
        // sit inside the sidebar card rather than on its top edge.
        let toolbar = NSToolbar(identifier: "KlikSettings")
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 920, height: 640))
        window.center()
        window.setFrameAutosaveName("KlikSettings")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Opens in front of every other app's windows and takes focus, however Klik
    /// was asked (the island, the menu bar, a hotkey — none of which activate it).
    /// With a `section`, that page is shown.
    func present(_ section: SettingsSection? = nil) {
        if let section { navigation.go(section) }
        showWindow(nil)
        guard let window else { return }
        window.orderFrontRegardless()
        NSApp.activateForOverlay(keyWindow: window)
        // The search field would take focus as the first field; the page reads better without a caret in it.
        window.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
