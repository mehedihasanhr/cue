import AppKit
import SwiftUI

/// The Settings window: native toolbar-style tabs (like System Settings / Xcode
/// preferences), each hosting a SwiftUI pane. The window resizes to fit the
/// selected pane.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private static let paneWidth: CGFloat = 560

    init(model: AppModel, shortcuts: ShortcutController, library: CaptureLibrary, clipboard: ClipboardHistory, preferences: AppPreferences) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = false

        tabs.addTabViewItem(Self.pane(
            "General", symbol: "gearshape", height: 780,
            GeneralSettingsView().environment(model).environment(library).environment(preferences)
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
            "Editor", symbol: "paintbrush.pointed", height: 780,
            EditorSettingsView().environment(preferences)
        ))
        tabs.addTabViewItem(Self.pane(
            "Shortcuts", symbol: "keyboard", height: 370,
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

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
