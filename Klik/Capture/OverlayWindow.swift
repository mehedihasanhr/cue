import AppKit

/// A borderless, transparent window covering one screen during area selection.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension NSApplication {
    /// Brings Klik front with `window` key for an overlay. A plain `activate()` is
    /// often refused right after a global hotkey or a click in the non-activating
    /// island; the refusal costs the first click (it only activates) and sends ⎋ to
    /// the user's app instead of the overlay.
    func activateForOverlay(keyWindow window: NSWindow) {
        activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.makeKeyAndOrderFront(nil)
        }
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
