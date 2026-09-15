import AppKit
import SwiftUI

/// The always-present panel docked on the notch. Non-activating, so hovering and
/// clicking never take the user's app out of front; `sharingType = .none` keeps it out
/// of every capture. It only becomes key when a control inside it (the search field)
/// is clicked. Hover is detected by `IslandController` from mouse-moved events: a
/// tracking area on a window over the notch never fires.
final class IslandWindow: NSPanel {
    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Set after `isFloatingPanel`, which resets the level to `.floating`. Above the
        // menu bar (24) and its status items (25) so the open panel covers them, below
        // pop-up menus (101) so the island's own menus still show on top.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        hidesOnDeactivate = false
        sharingType = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps windows below the menu bar; the island lives on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
