import AppKit
import SwiftUI

/// The Settings window: native toolbar-style tabs (like System Settings / Xcode
/// preferences), each hosting a SwiftUI pane. The window resizes to fit the
/// selected pane.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private static let paneWidth: CGFloat = 560

    init(model: AppModel, shortcuts: ShortcutController, library: CaptureLibrary, clipboard: ClipboardHistory, preferences: AppPreferences, clock: PrayerClock? = nil) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = false

        tabs.addTabViewItem(Self.pane(
            "General", symbol: "gearshape", height: 520,
            GeneralSettingsView().environment(model).environment(library).environment(preferences)
        ))
        tabs.addTabViewItem(Self.pane(
            "Island", symbol: "rectangle.topthird.inset.filled", height: 470,
            IslandSettingsView().environment(preferences)
        ))
        tabs.addTabViewItem(Self.pane(
            "Capture", symbol: "camera", height: 330,
            CaptureSettingsView().environment(preferences)
        ))
        tabs.addTabViewItem(Self.pane(
            "Clipboard", symbol: "doc.on.clipboard", height: 340,
            ClipboardSettingsView().environment(clipboard).environment(preferences)
        ))
        tabs.addTabViewItem(Self.pane(
            "Editor", symbol: "paintbrush.pointed", height: 560,
            EditorSettingsView().environment(preferences)
        ))
        tabs.addTabViewItem(Self.pane(
            "Time", symbol: "clock", height: 560,
            TimeSettingsView().environment(preferences).environment(clock)
        ))
        tabs.addTabViewItem(Self.pane(
            "Shortcuts", symbol: "keyboard", height: 410,
            ShortcutSettingsView().environment(shortcuts)
        ))
        tabs.addTabViewItem(Self.pane(
            "Permissions", symbol: "lock.shield", height: 300,
            PermissionSettingsView().environment(model)
        ))
        tabs.addTabViewItem(Self.pane(
            "About", symbol: "info.circle", height: 300,
            AboutSettingsView()
        ))

        let window = NSWindow(contentViewController: tabs)
        window.title = "Klik Settings"
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func pane(_ title: String, symbol: String, height: CGFloat, _ view: some View) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.frame(width: paneWidth, height: height))
        host.title = title
        host.preferredContentSize = CGSize(width: paneWidth, height: height)
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    /// Opens in front of every other app's windows and takes focus, however Klik
    /// was asked (the island, the menu bar, a hotkey — none of which activate it).
    func present() {
        showWindow(nil)
        guard let window else { return }
        window.orderFrontRegardless()
        NSApp.activateForOverlay(keyWindow: window)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
