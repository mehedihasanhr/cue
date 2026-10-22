import AppKit
import SwiftUI

/// The window Recordings lives in.
///
/// An `NSWindowController` rather than a SwiftUI `Window` scene, for the same reason the
/// editor is one. A `Window` scene opens itself at launch whether or not the app wants it,
/// and — once the editors stopped being scenes, so SwiftUI could see none of its own
/// windows on screen — opened itself again on every activation. Three separate attempts to
/// dismiss it from the outside each worked until the next thing SwiftUI did.
///
/// The app is the floating bar. Recordings is somewhere you go, so it exists when it is
/// asked for and not before.
@MainActor
final class LibraryWindowController: NSWindowController {
    init(model: RecorderModel?, studio: StudioService, settings: StudioSettings) {
        let window = RecordingsWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "Recordings"
        // The title is written large in the window itself, under a bar that is part of the
        // page rather than a grey strip above it.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 520, height: 440)
        // macOS must not bring this back by itself.
        //
        // An AppKit window is restorable by default, so having taken Recordings out of
        // SwiftUI — which reopened it on every activation — it promptly started reopening
        // itself at launch instead, from saved window state. The app is the bar; this is
        // somewhere you go. It appears when it is asked for, and at no other time.
        window.isRestorable = false

        let hosting = NSHostingController(rootView: LibraryWindow(model: model)
            .environment(studio)
            .environment(settings))
        // The window's size is the window's business — the same reason the editor says so.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(CGSize(width: 760, height: 640))
        window.setFrameAutosaveName("CueStudioRecordings")

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        StudioAutomation.present(self)
    }
}

/// The Recordings window, with its traffic lights in the middle of the header row.
///
/// The header is drawn in the title bar (`LibraryWindow.header`), and is taller than the
/// title bar the system draws, so the buttons are moved down to its middle. An empty
/// toolbar would have made the title bar that tall by itself, but a toolbar sits over
/// the content and took every click meant for the header's controls.
final class RecordingsWindow: NSWindow {
    private var observers: [NSObjectProtocol] = []

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        // AppKit lays the title bar out again on each of these, putting the buttons back.
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.centerTrafficLights() }
            })
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        centerTrafficLights()
    }

    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        centerTrafficLights()
    }

    /// Puts the close, minimise and zoom buttons in the middle of the header row, and
    /// makes the strip that holds them that tall. Full screen keeps the system's own.
    func centerTrafficLights() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton),
              let container = close.superview?.superview,
              let frameView = container.superview else { return }
        let height = LibraryWindow.headerHeight
        let wanted = CGRect(x: container.frame.minX, y: frameView.bounds.height - height,
                            width: container.frame.width, height: height)
        if container.frame != wanted { container.frame = wanted }
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(kind) else { continue }
            let y = ((height - button.frame.height) / 2).rounded()
            if button.frame.minY != y { button.setFrameOrigin(CGPoint(x: button.frame.minX, y: y)) }
        }
    }
}
