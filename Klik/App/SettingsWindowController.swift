import AppKit
import SwiftUI

/// The Settings window: a sidebar of pages (searchable, an icon tile each) and
/// the chosen page on the right — the layout of System Settings and Raycast.
/// The title bar is transparent so the sidebar runs to the top, under the
/// traffic lights; the window remembers its size and the last page.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let navigation = SettingsNavigation()

    init(model: AppModel, shortcuts: ShortcutController, library: CaptureLibrary, clipboard: ClipboardHistory, preferences: AppPreferences, addOns: AddOnRegistry, studio: StudioPreferences, clock: PrayerClock? = nil, share: ShareSettings? = nil, sync: SyncFolder? = nil, notes: NoteStore? = nil, taskSync: TaskSync? = nil, ocrEngines: OCREngines? = nil) {
        // The window is made first so the traffic lights can reach it.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 920, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let buttons = WindowButtons(close: { [weak window] in window?.performClose(nil) },
                                    minimize: { [weak window] in window?.miniaturize(nil) },
                                    zoom: { [weak window] in window?.zoom(nil) })
        let root = SettingsRootView(buttons: buttons)
            .environment(navigation)
            .environment(model)
            .environment(shortcuts)
            .environment(library)
            .environment(clipboard)
            .environment(preferences)
            .environment(addOns)
            .environment(studio)
            .environment(clock)
            .environment(share)
            .environment(sync)
            .environment(notes)
            .environment(taskSync)
            .environment(ocrEngines)
            .frame(minWidth: 820, minHeight: 540)

        window.contentViewController = NSHostingController(rootView: root)
        window.title = "Klik Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The content draws the window: glass with a 24 pt corner, and its own
        // traffic lights inside the sidebar card, so the system's are hidden.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
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
        NSApp.present(window)
        // The search field would take focus as the first field; the page reads better without a caret in it.
        window.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
