import AppKit
import SwiftUI

/// The always-present panel docked on the notch. Non-activating, so hovering and
/// clicking never take the user's app out of front. It is shareable (`.readOnly`) so
/// it shows in screen sharing and recordings; Cue's own screenshots leave it out
/// through their capture filter instead. It only becomes key when a control inside
/// it (the search field) is clicked. Hover is detected by `IslandController` from mouse-moved events: a
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
        // menu bar (24), its status items (25), every app window and Cue's own floating
        // panels (which sit at `.floating`) so cards can be dragged from the island into
        // them; just below pop-up menus (101) so the island's own menus still show on top.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        hidesOnDeactivate = false
        sharingType = .readOnly
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

    /// Liquid Glass draws flat grey in a window without an active appearance, and the
    /// island opens on hover without taking the keyboard: without this, its glass came
    /// alive only once clicked. AppKit asks these (private) questions to pick that look;
    /// the island always answers as if it were in front. Key status itself is untouched.
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    /// AppKit keeps windows below the menu bar; the island lives on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    var onEscape: (() -> Void)?
    /// ← (-1) or → (+1) pressed with nothing in the island taking it (no field is
    /// being typed in): the panel walks its cards.
    var onArrow: ((Int) -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if !(firstResponder is NSTextView), event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            switch event.keyCode {
            case 123: onArrow?(-1); return
            case 124: onArrow?(1); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

/// SwiftUI in a window that is not key: a `Button` answers the first click, a tap
/// gesture does not — AppKit asks the hosting view whether it accepts first mouse,
/// and the plain one says no, so the click only makes the window key and the card
/// copies on the second. The island and its pane are clicked while another app is
/// in front, so their hosting views take every first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The island's content view doubles as a drop target: files and images dragged
/// onto the notch or the open panel go on the shelf or are saved as assets.
final class IslandDropView: NSView {
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    /// The pointer moved during the drag (screen coordinates).
    var onDragMoved: ((CGPoint) -> Void)?
    /// File URLs and/or raw image data from the drop.
    var onDrop: (([URL], Data?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard IslandDrag.current == nil, Self.canAccept(sender) else { return [] }
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard IslandDrag.current == nil, Self.canAccept(sender) else { return [] }
        if let window { onDragMoved?(window.convertPoint(toScreen: sender.draggingLocation)) }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard IslandDrag.current == nil else { return false }
        let pasteboard = sender.draggingPasteboard
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let image = urls.isEmpty ? (pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)) : nil
        guard !urls.isEmpty || image != nil else { return false }
        onDrop?(urls, image)
        return true
    }

    private static func canAccept(_ info: any NSDraggingInfo) -> Bool {
        // Never accept the island's own drags (an asset dragged out and back in).
        guard (info.draggingSource as? NSView)?.window !== info.draggingDestinationWindow else { return false }
        let types = info.draggingPasteboard.types ?? []
        return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff)
    }
}
