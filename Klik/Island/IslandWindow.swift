import AppKit
import SwiftUI

/// The always-present panel docked on the notch. Non-activating, so hovering and
/// clicking never take the user's app out of front. It is shareable (`.readOnly`) so
/// it shows in screen sharing and recordings; Klik's own screenshots leave it out
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
        // menu bar (24), its status items (25), every app window and Klik's own floating
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

    /// AppKit keeps windows below the menu bar; the island lives on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// The island's content view doubles as a drop target: files and images dragged
/// onto the notch or the open panel are saved as assets.
final class IslandDropView: NSView {
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
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
        IslandDrag.current == nil && Self.canAccept(sender) ? .copy : []
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
