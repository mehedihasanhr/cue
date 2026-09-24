import os
import AppKit
import Observation
import SwiftUI

/// The editor windows, and which of them is in front.
///
/// The editor used to be a SwiftUI `WindowGroup` opened through `openWindow`, which meant
/// three things nobody chose. Opening one depended on a scene modifier firing, and the
/// scene it was attached to is closed at launch — so a recording opened from the Finder,
/// or a take that had just stopped, often opened nothing at all. SwiftUI also opened a
/// window of its own at launch, sometimes blank and sometimes carrying a recording it had
/// remembered. And the app could not say how many editors were open, which is what the
/// recorder bar needs to know to get out of the way.
///
/// Owning the windows in AppKit answers all three. Opening one is a method call with a
/// result, the count is a fact rather than an inference, and nothing opens that was not
/// asked for.
@MainActor
@Observable
final class EditorWindows {
    /// The editor the menu bar acts on. Set as windows become main, so ⌘Z goes to the
    /// window you are looking at.
    private(set) var front: EditorSession?

    /// One window per recording, so opening the same one twice brings it forward rather
    /// than making a second editor for one file.
    private var controllers: [URL: EditorWindowController] = [:]

    @ObservationIgnored private var settings: StudioSettings?

    /// Told whenever an editor opens or closes. The bar listens, because "is an editor on
    /// screen?" is the whole of its visibility rule.
    @ObservationIgnored var onChange: (() -> Void)?

    var isEmpty: Bool { controllers.isEmpty }

    func configure(settings: StudioSettings) {
        self.settings = settings
    }

    /// Opens a recording for editing, or brings its window forward if it is already open.
    func open(_ url: URL) {
        let key = Self.key(for: url)
        if let existing = controllers[key] {
            existing.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let settings else {
            StudioLog.app.error("An editor was asked for before the app had finished starting")
            return
        }

        let controller = EditorWindowController(session: EditorSession(packageURL: url),
                                                settings: settings,
                                                windows: self)
        controllers[key] = controller
        // Offset from the last one so a second take does not land exactly on the first.
        if let window = controller.window {
            if let previous = controllers.values.first(where: { $0 !== controller })?.window {
                window.setFrameTopLeftPoint(previous.frame.origin.applying(.init(translationX: 24, y: -24)))
                window.cascadeTopLeft(from: previous.frame.origin)
            } else {
                window.center()
            }
        }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        onChange?()
    }

    /// Closes every editor. Used at launch, when anything still open is left over rather
    /// than asked for.
    func closeAll() {
        for controller in controllers.values { controller.close() }
    }

    // MARK: - Told by the windows

    func becameFront(_ session: EditorSession) {
        front = session
    }

    func closed(_ controller: EditorWindowController) {
        controllers[Self.key(for: controller.session.packageURL)] = nil
        // The menu must not keep acting on a window that has gone.
        if front === controller.session { front = controllers.values.first?.session }

        // Told on the next turn of the run loop, not this one.
        //
        // This is reached from `windowWillClose`, which fires *while* the window is going:
        // it is still in the window list, still visible, and AppKit has not yet handed key
        // and main to whatever is left. Bringing the recorder bar up inside that moment
        // puts it in front of a reshuffle that is still happening, and it loses — the bar
        // is ordered front and then ordered straight back out, so closing the last editor
        // left the app with nothing on screen at all.
        Task { @MainActor in self.onChange?() }
    }

    /// The same recording reached by two different paths — a Finder open and a row in the
    /// library — must be one window, so the key is the resolved path rather than whatever
    /// spelling arrived.
    private static func key(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// The window one recording is edited in.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let session: EditorSession
    private let windows: EditorWindows

    init(session: EditorSession, settings: StudioSettings, windows: EditorWindows) {
        self.session = session
        self.windows = windows

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        // The editor draws its own title bar (`EditorToolbar`), so the system's is emptied
        // and the content runs to the top of the window with the traffic lights over it.
        // Safe to say here, unlike on a window SwiftUI is managing, because this one is
        // ours from the moment it is made.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Still set: it is the name the Window menu and Mission Control read.
        window.title = session.packageURL.deletingPathExtension().lastPathComponent
        window.isReleasedWhenClosed = false

        let hosting = NSHostingController(rootView: EditorView(session: session).environment(settings))
        // The window decides its own size, not the view.
        //
        // A hosting controller reports its SwiftUI content's ideal size as a preferred
        // content size, and AppKit resizes the window to match. While a recording is still
        // loading that content is a progress spinner, so the editor opened as a 926 × 444
        // window and then stayed that size. Nothing here wants that: an editor opens at a
        // size worth editing in.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(CGSize(width: 1_280, height: 860))
        window.contentMinSize = CGSize(width: 960, height: 680)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowDidBecomeMain(_ notification: Notification) {
        windows.becameFront(session)
    }

    func windowWillClose(_ notification: Notification) {
        windows.closed(self)
    }
}
