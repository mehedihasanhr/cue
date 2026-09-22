import AppKit
import SwiftUI

/// The task form as a floating window at the pointer (⌥/), for jotting a task
/// down from anywhere without going to the island. Frosted dark glass with a grain
/// so text stays legible over anything; the island's cards (captures, clipboard
/// entries, assets, colors) can be dragged into its description or pasted there.
/// Moves by the strip along its top, so a drag in the text selects. Closes on ⎋,
/// on Create / Cancel, on a click outside, or when it loses key status — unless it
/// is pinned, when only ⎋ and the form's own buttons close it. The note form adds
/// a corner grip to resize it and can turn its glass clearer.
final class QuickTaskPanel: NSPanel {
    static let defaultSize = CGSize(width: IslandGeometry.formWidth, height: IslandGeometry.formContentHeight + 8)
    /// Room around the glass for its shadow.
    private static let margin: CGFloat = 24
    private var monitors: [Any] = []
    private let finish: (PromptAnswer?) -> Void
    /// The glass's size, pin and clarity; the form reads and changes them through the environment.
    let chrome = Chrome()

    /// What the form can see and change about its window.
    @Observable
    final class Chrome {
        var size = QuickTaskPanel.defaultSize
        /// Pinned: stays open above other apps until closed on purpose.
        var pinned = false {
            didSet { panel?.pinnedDidChange() }
        }
        /// 0: frosted (the default); 1: nearly clear glass.
        var clarity: Double = 0
        weak var panel: QuickTaskPanel?
    }

    /// The glass at `size`, keeping its top-left corner where it is.
    private struct Sized<Content: View>: View {
        let chrome: Chrome
        let content: Content

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            content
                .padding(.top, 8)
                .frame(width: chrome.size.width, height: chrome.size.height)
                .liquidGlass(cornerRadius: 22, clarity: chrome.clarity)
                // One pane, its edge lit from the top like the light catching glass.
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(stops: [.init(color: Color(red: 0.55, green: 0.5, blue: 0.95).opacity(0.7), location: 0),
                                               .init(color: Color(red: 0.35, green: 0.75, blue: 0.8).opacity(0.35), location: 0.25),
                                               .init(color: .primary.opacity(0.1), location: 0.6),
                                               .init(color: .primary.opacity(0.08), location: 1)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                )
                .padding(QuickTaskPanel.margin)
                .environment(chrome)
        }
    }

    convenience init(store: TaskStore, prompt: IslandPrompt = IslandPrompt(kind: .task(project: nil)), finish: @escaping (PromptAnswer?) -> Void) {
        self.init(finish: finish) { close in
            TaskFormRow(prompt: prompt, store: store, style: .floating) { answer in
                finish(answer)
                close()
            }
        }
    }

    /// Any of the island's forms (a snippet, its blanks) as a floating window.
    convenience init(form: some View) {
        self.init(finish: { _ in }) { _ in form }
    }

    private init(finish: @escaping (PromptAnswer?) -> Void, form: (@escaping () -> Void) -> some View) {
        self.finish = finish
        super.init(
            contentRect: CGRect(origin: .zero, size: CGSize(width: Self.defaultSize.width + Self.margin * 2, height: Self.defaultSize.height + Self.margin * 2)),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // `.floating`: above ordinary windows, below the Dynamic Island so its cards can
        // be dragged in here even when the two overlap.
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the glass draws its own
        isMovableByWindowBackground = false // the strip along the top moves it
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        sharingType = .readOnly // shows in screen sharing; Klik's own shots filter it out
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow

        chrome.panel = self
        let root = Sized(chrome: chrome, content: form { [weak self] in self?.close() })
        let host = NSHostingView(rootView: root)
        let full = CGRect(origin: .zero, size: CGSize(width: Self.defaultSize.width + Self.margin * 2, height: Self.defaultSize.height + Self.margin * 2))
        host.frame = full
        host.autoresizingMask = [.width, .height]
        // Anything dropped on the panel — not just on the editor — goes into the description.
        let container = DropCatcher(frame: full)
        container.editor = { [weak self] in self?.editor as? RichTextView }
        container.addSubview(host)
        // Above the form, but only the edge bands take the mouse.
        let resizer = EdgeResizer(frame: full)
        resizer.autoresizingMask = [.width, .height]
        container.addSubview(resizer)
        contentView = container
    }

    /// The panel's content view: forwards files and images dropped anywhere on the
    /// glass to the description editor.
    private final class DropCatcher: NSView {
        var editor: () -> RichTextView? = { nil }

        override init(frame: CGRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL, .png, .tiff])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard let editor = editor() else { return false }
            editor.window?.makeFirstResponder(editor)
            return editor.takeContent(from: sender.draggingPasteboard)
        }
    }

    /// The frame's edges and corners, like any other window: a band just inside the
    /// glass that takes the drag, sitting above the form but letting every other
    /// click through to it.
    private final class EdgeResizer: NSView {
        /// How wide the grab band is, inside and outside the glass edge.
        private static let band: CGFloat = 7
        private struct Edges: OptionSet {
            let rawValue: Int
            static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
        }
        private var drag: (edges: Edges, frame: CGRect, pointer: CGPoint)?

        override var mouseDownCanMoveWindow: Bool { false }
        private var panel: QuickTaskPanel? { window as? QuickTaskPanel }

        /// The glass's rect inside the frame (the rest is room for its shadow).
        private var glass: CGRect { bounds.insetBy(dx: QuickTaskPanel.margin, dy: QuickTaskPanel.margin) }

        private func edges(at point: CGPoint) -> Edges {
            let glass = glass
            guard glass.insetBy(dx: -Self.band, dy: -Self.band).contains(point) else { return [] }
            var edges: Edges = []
            if abs(point.x - glass.minX) <= Self.band { edges.insert(.left) }
            if abs(point.x - glass.maxX) <= Self.band { edges.insert(.right) }
            if abs(point.y - glass.minY) <= Self.band { edges.insert(.bottom) }
            if abs(point.y - glass.maxY) <= Self.band { edges.insert(.top) }
            return edges
        }

        // Only the bands take the mouse; everything else belongs to the form below.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return edges(at: local).isEmpty ? nil : self
        }

        override func resetCursorRects() {
            let glass = glass, band = Self.band
            let horizontal = NSCursor.resizeLeftRight, vertical = NSCursor.resizeUpDown
            addCursorRect(CGRect(x: glass.minX - band, y: glass.minY, width: band * 2, height: glass.height), cursor: horizontal)
            addCursorRect(CGRect(x: glass.maxX - band, y: glass.minY, width: band * 2, height: glass.height), cursor: horizontal)
            addCursorRect(CGRect(x: glass.minX, y: glass.minY - band, width: glass.width, height: band * 2), cursor: vertical)
            addCursorRect(CGRect(x: glass.minX, y: glass.maxY - band, width: glass.width, height: band * 2), cursor: vertical)
            // The corners get the matching diagonal where the system has one.
            if #available(macOS 15.0, *) {
                let corners: [(CGPoint, NSCursor)] = [
                    (CGPoint(x: glass.minX, y: glass.minY), .frameResize(position: .bottomLeft, directions: .all)),
                    (CGPoint(x: glass.maxX, y: glass.minY), .frameResize(position: .bottomRight, directions: .all)),
                    (CGPoint(x: glass.minX, y: glass.maxY), .frameResize(position: .topLeft, directions: .all)),
                    (CGPoint(x: glass.maxX, y: glass.maxY), .frameResize(position: .topRight, directions: .all)),
                ]
                for (corner, cursor) in corners {
                    addCursorRect(CGRect(x: corner.x - band, y: corner.y - band, width: band * 2, height: band * 2), cursor: cursor)
                }
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let panel else { return }
            let local = convert(event.locationInWindow, from: nil)
            let edges = edges(at: local)
            guard !edges.isEmpty else { return }
            drag = (edges, panel.frame, NSEvent.mouseLocation)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let panel, let drag else { return }
            let pointer = NSEvent.mouseLocation
            let dx = pointer.x - drag.pointer.x, dy = pointer.y - drag.pointer.y
            var frame = drag.frame
            if drag.edges.contains(.right) { frame.size.width += dx }
            if drag.edges.contains(.left) { frame.origin.x += dx; frame.size.width -= dx }
            if drag.edges.contains(.bottom) { frame.origin.y += dy; frame.size.height -= dy }
            if drag.edges.contains(.top) { frame.size.height += dy }
            panel.setGlassFrame(frame, anchoredLeft: !drag.edges.contains(.left), anchoredBottom: !drag.edges.contains(.bottom))
        }

        override func mouseUp(with event: NSEvent) { drag = nil }
    }

    override var canBecomeKey: Bool { true }

    /// Resizes the glass to `size` (the window grows around it), keeping the top-left
    /// corner in place and staying on screen; never larger than the screen itself.
    func resize(to size: CGSize, animated: Bool = true) {
        let limit = Self.limit(on: screen ?? NSScreen.main)
        let size = CGSize(width: min(size.width.rounded(), limit.width), height: min(size.height.rounded(), limit.height))
        guard size != chrome.size else { return }
        chrome.size = size
        var frame = frame
        let full = CGSize(width: size.width + Self.margin * 2, height: size.height + Self.margin * 2)
        frame.origin.y = frame.maxY - full.height
        frame.size = full
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX - Self.margin + 8), visible.maxX - full.width + Self.margin - 8)
            frame.origin.y = min(max(frame.minY, visible.minY - Self.margin + 8), visible.maxY - full.height + Self.margin - 8)
        }
        setFrame(frame, display: true, animate: animated)
    }

    /// The largest a form may grow itself to: 60 % of the screen either way.
    static func maxSize(on screen: NSScreen?) -> CGSize {
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(width: (visible.width * 0.6).rounded(), height: (visible.height * 0.6).rounded())
    }

    /// The largest the glass may be dragged to: the whole screen, less the room its
    /// shadow needs on either side.
    static func limit(on screen: NSScreen?) -> CGSize {
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(width: (visible.width - margin * 2).rounded(), height: (visible.height - margin * 2).rounded())
    }

    /// The window frame a drag on an edge asks for, clamped to the smallest and
    /// largest glass and kept on screen; `anchored…` is the side that must not move.
    func setGlassFrame(_ wanted: CGRect, anchoredLeft: Bool, anchoredBottom: Bool) {
        let limit = Self.limit(on: screen ?? NSScreen.main)
        let size = CGSize(width: min(max((wanted.width - Self.margin * 2).rounded(), Self.defaultSize.width), limit.width),
                          height: min(max((wanted.height - Self.margin * 2).rounded(), Self.defaultSize.height), limit.height))
        guard size != chrome.size else { return }
        chrome.size = size
        let full = CGSize(width: size.width + Self.margin * 2, height: size.height + Self.margin * 2)
        var frame = CGRect(origin: CGPoint(x: anchoredLeft ? wanted.minX : wanted.maxX - full.width,
                                           y: anchoredBottom ? wanted.minY : wanted.maxY - full.height),
                           size: full)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX - Self.margin + 8), visible.maxX - full.width + Self.margin - 8)
            frame.origin.y = min(max(frame.minY, visible.minY - Self.margin + 8), visible.maxY - full.height + Self.margin - 8)
        }
        setFrame(frame, display: true)
    }

    /// The description editor, for pasting island cards into it.
    var editor: NSTextView? {
        func find(in view: NSView) -> NSTextView? {
            if let editor = view as? RichTextView { return editor }
            for subview in view.subviews { if let found = find(in: subview) { return found } }
            return nil
        }
        return contentView.flatMap(find)
    }

    /// Shows the form at `position` on the pointer's screen (at the pointer: its
    /// top-left corner just under it), kept on screen.
    func show(at point: CGPoint, position: PanelPosition = .pointer) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        setFrameOrigin(position.origin(windowSize: frame.size, margin: Self.margin, pointer: point, visible: visible))
        makeKeyAndOrderFront(nil)
        installMonitors()
    }

    override func close() {
        removeMonitors()
        super.close()
    }

    override func cancelOperation(_ sender: Any?) {
        finish(nil)
        close()
    }

    override func resignKey() {
        super.resignKey()
        // A menu (the project dropdown) takes key status briefly; only a real switch closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !isPinned, isVisible, !isKeyWindow, NSApp.keyWindow == nil || NSApp.keyWindow?.isKind(of: NSPanel.self) == false else { return }
            close()
        }
    }

    // MARK: Pinning

    var isPinned: Bool { chrome.pinned }

    /// Pinned, the panel stops closing on its own: no click-outside monitor, no
    /// close on losing key status, and it stays put when the app switches.
    private func pinnedDidChange() {
        if chrome.pinned {
            removeMonitors()
            collectionBehavior.remove(.transient)
        } else {
            collectionBehavior.insert(.transient)
            if isVisible { installMonitors() }
        }
    }

    private func installMonitors() {
        removeMonitors()
        guard !chrome.pinned else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

