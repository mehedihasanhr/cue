import AppKit

/// A borderless, transparent panel covering one screen during area selection.
///
/// A *non-activating* panel, because Klik must not become the active app to show it:
/// activating an agent app brings its other windows forward, and macOS follows them
/// to the desktop they live on — which slid the user off the very thing they were
/// capturing. A panel takes the keyboard without that, so ⎋, ↩, ⌘A and the arrow
/// nudges still reach `SelectionView` while the app underneath stays in front.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        // Clears a full-screen app's own window (level 0 inside its Space), the menu
        // bar and the island. Membership of the Space is what the collection
        // behaviour below grants; the level only settles the stacking.
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps windows below the menu bar; the overlay covers the whole display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

extension NSApplication {
    /// Brings `window` to the front with the keyboard, for the windows the user asked
    /// for and expects in front: Settings, onboarding, a prompt form.
    ///
    /// These windows genuinely need Klik activated. macOS 14's cooperative
    /// `activate()` will not do it on its own — AppKit's own note is that it "does not
    /// guarantee that the app will be activated at all", because it waits for the app
    /// in front to call `yieldActivationToApplication:`, and nothing ever yields to a
    /// menu-bar app. Left at that, Settings ordered to the front of Klik's own windows
    /// and stayed behind whatever the user was working in.
    ///
    /// What is still avoided is `.activateAllWindows`. That is what brings *every*
    /// Klik window forward and makes macOS follow them to the desktop they were left
    /// on — the thing that used to drag the user off the Space they were capturing.
    /// Plain activation plus `.moveToActiveSpace` brings this one window to the user
    /// instead of taking the user to it. The capture overlay does not come through
    /// here at all: it is a non-activating panel and must stay one.
    func present(_ window: NSWindow, key: Bool = true) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        // Activate first. Once Klik is frontmost the window orders above every other
        // app's; the other way round it only orders above Klik's own.
        activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        if key { window.makeKeyAndOrderFront(nil) }
    }
}

/// Builds the per-screen overlay: the frozen screenshot underneath, the interactive
/// `SelectionView` on top.
final class OverlayWindowController: NSWindowController {
    let screen: NSScreen
    let frozen: CapturedImage
    let selectionView: SelectionView

    init(screen: NSScreen, frozen: CapturedImage, mode: CaptureMode, windows: [WindowInfo], delegate: SelectionViewDelegate) {
        self.screen = screen
        self.frozen = frozen

        let window = OverlayWindow(screen: screen)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)

        let content = NSView(frame: bounds)
        content.wantsLayer = true

        let imageView = NSView(frame: bounds)
        imageView.wantsLayer = true
        imageView.layer?.contents = frozen.cgImage
        imageView.layer?.contentsGravity = .resize
        imageView.autoresizingMask = [.width, .height]

        selectionView = SelectionView(frame: bounds, frozen: frozen, mode: mode)
        selectionView.windows = windows
        selectionView.delegate = delegate
        selectionView.autoresizingMask = [.width, .height]

        content.addSubview(imageView)
        content.addSubview(selectionView)
        window.contentView = content
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present(makeKey: Bool) {
        window?.orderFrontRegardless()
        if makeKey {
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(selectionView)
        }
    }
}
