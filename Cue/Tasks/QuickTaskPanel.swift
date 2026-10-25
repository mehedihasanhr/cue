import AppKit
import SwiftUI

/// The task form as a floating window at the pointer (⌥/), for jotting a task
/// down from anywhere without going to the island. Frosted dark glass with a grain
/// so text stays legible over anything; the island's cards (captures, clipboard
/// entries, assets, colors) can be dragged into its description or pasted there.
/// Moves by the strip along its top, so a drag in the text selects. Closes on ⎋,
/// on Create / Cancel, on a click outside, or when it loses key status — unless it
/// is pinned, when only ⎋ and the form's own buttons close it. The task form is
/// always pinned. The note form adds
/// a corner grip to resize it and can turn its glass clearer.
final class QuickTaskPanel: NSPanel {
    static let defaultSize = CGSize(width: IslandGeometry.formWidth, height: IslandGeometry.formContentHeight + 8)
    /// Room around the glass for its shadow.
    private static let margin: CGFloat = 24
    private var monitors: [Any] = []
    private let finish: (PromptAnswer?) -> Void
    /// Watches for the user switching Spaces — see `activeSpaceChanged`.
    private var spaceObserver: (any NSObjectProtocol)?
    /// When this panel last lost key status, to tell whether it still had the keyboard
    /// when its Space was left (the switch takes key status a moment before it is
    /// announced).
    private var resignedKeyAt: Date?
    /// It had the keyboard when its Space was left: it takes it back on the way in.
    private var refocusOnReturn = false
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
        /// The island's dark smoked glass, or Raycast's frosted panel (the task form).
        var look: Look = .smoke
        weak var panel: QuickTaskPanel?

        enum Look { case smoke, raycast }
    }

    /// Raycast's panel: the desktop frosted behind a light (or, in Dark Mode, deep
    /// grey) veil, a hairline edge and a soft shadow — following the system's appearance.
    private enum RaycastGlass {
        /// White at 95 % over the blurred desktop (a deep grey at the same strength in
        /// Dark Mode): solid enough to read on, with the backdrop still coming through.
        static let veil = NotionStyle.dynamic(light: NotionStyle.rgb(255, 255, 255, 0.95), dark: NotionStyle.rgb(32, 32, 34, 0.95))
        /// A grey hairline all round.
        static let edge = NotionStyle.dynamic(light: NotionStyle.rgb(0, 0, 0, 0.12), dark: NotionStyle.rgb(255, 255, 255, 0.14))
        /// Light catching the top of the glass.
        static let sheen = NotionStyle.dynamic(light: NotionStyle.rgb(255, 255, 255, 0.6), dark: NotionStyle.rgb(255, 255, 255, 0.05))
    }

    /// The glass at `size`, keeping its top-left corner where it is.
    private struct Sized<Content: View>: View {
        let chrome: Chrome
        let content: Content

        /// The island's ink: a blue-black that reads as glass, not grey.
        private static var ink: Color { Color(red: 0.03, green: 0.035, blue: 0.05) }

        var body: some View {
            if chrome.look == .raycast { raycast } else { smoke }
        }

        private var raycast: some View {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            return content
                .frame(width: chrome.size.width, height: chrome.size.height)
                // The content is clipped to the rounded glass; the glass's shadow is not,
                // so it falls outside the edge into the window's margin.
                .clipShape(shape)
                .background {
                    ZStack {
                        // The backdrop: the desktop behind the window, blurred.
                        GlassMaterial(material: .hudWindow)
                        RaycastGlass.veil
                        LinearGradient(colors: [RaycastGlass.sheen, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.25))
                    }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(RaycastGlass.edge, lineWidth: 1))
                    // A soft shadow, a little below: lifts it off whatever is behind.
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
                    .allowsHitTesting(false)
                }
                .padding(QuickTaskPanel.margin)
                .environment(chrome)
        }

        private var smoke: some View {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            let solid = 1 - min(max(chrome.clarity, 0), 1)
            return content
                .padding(.top, 8)
                .frame(width: chrome.size.width, height: chrome.size.height)
                // The island's look, as a window: dark smoked glass with the same slow
                // smoke drifting through it, light falling from the top edge, and no
                // outline — the shadow sets it off whatever lies behind.
                .background {
                    ZStack {
                        Self.ink.opacity(0.55 + 0.37 * solid)
                        SmokeField(palette: Smoke.calm, intensity: 0.75 * solid, fadeTop: 0)
                        LinearGradient(colors: [.white.opacity(0.07 * solid + 0.02), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
                    }
                    .background(.ultraThinMaterial)
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    .allowsHitTesting(false)
                }
                .clipShape(shape)
                .environment(\.colorScheme, .dark)
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
        // A task is written slowly, often while looking at something else: it stays
        // until its own buttons or ⎋ close it, never on a click elsewhere.
        chrome.pinned = true
        useRaycastLook()
        // Left to itself the window server lets clicks fall through where the glass
        // looks see-through (the top strip), into the app behind: set explicitly,
        // the window takes every click in its frame.
        ignoresMouseEvents = false
    }

    /// The task and note forms' look: Raycast's frosted white panel, wide enough for a
    /// sentence on one line, moved by a thin band along its top edge (it has no grabber).
    func useRaycastLook(size: CGSize = CGSize(width: 640, height: 380)) {
        chrome.look = .raycast
        resize(to: size, animated: false)
        movesByTopStrip = true
        stripHeight = 16
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
        sharingType = .readOnly // shows in screen sharing; Cue's own shots filter it out
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        }

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

    /// The editing keys, handled here. The panel does not activate Cue, so ⌘V never
    /// reaches the Edit menu (it is only consulted for the active app) and pasting a
    /// capture did nothing; each goes straight to whatever has the caret instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let action: Selector? = switch (flags, key) {
        case (.command, "v"): #selector(NSText.paste(_:))
        case ([.command, .option, .shift], "v"): #selector(NSTextView.pasteAsPlainText(_:))
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        default: nil
        }
        // A SwiftUI control may claim the key first (a shortcut on a button).
        if super.performKeyEquivalent(with: event) { return true }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return false
    }

    /// The task form's top strip (the grabber) moves the window. Caught here, before
    /// the form sees the click, so it works whatever the SwiftUI views under it do.
    private var movesByTopStrip = false
    private var stripHeight: CGFloat = 32

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, movesByTopStrip, onTopStrip(event.locationInWindow) {
            move(from: event)
            return
        }
        super.sendEvent(event)
    }

    /// Under the glass's top edge, clear of the resize band above and the close
    /// button at the right end.
    private func onTopStrip(_ point: CGPoint) -> Bool {
        guard let bounds = contentView?.bounds else { return false }
        let glass = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        return point.y < glass.maxY - 7 && point.y > glass.maxY - stripHeight
            && point.x > glass.minX + 7 && point.x < glass.maxX - 44
    }

    private func move(from event: NSEvent) {
        let start = NSEvent.mouseLocation, origin = frame.origin
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let pointer = NSEvent.mouseLocation
            setFrameOrigin(CGPoint(x: origin.x + pointer.x - start.x, y: origin.y + pointer.y - start.y))
        }
    }

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
        refocusOnReturn = false
        // A panel is made for each showing and not shown again once closed.
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        super.close()
    }

    /// A pinned panel lives on the Space it was opened on (see `pinnedDidChange`). Leaving
    /// that Space while typing in it, then coming back, puts the keyboard back in it, as
    /// macOS does for an ordinary app's window — but not, left to itself, for a panel of
    /// a menu bar app, which came back unfocused under whatever had been clicked since.
    private func activeSpaceChanged() {
        guard isVisible else { return }
        if isOnActiveSpace {
            guard refocusOnReturn else { return }
            refocusOnReturn = false
            makeKeyAndOrderFront(nil)
        } else {
            refocusOnReturn = isKeyWindow || resignedKeyAt.map { Date().timeIntervalSince($0) < 1 } == true
        }
    }

    override func cancelOperation(_ sender: Any?) {
        finish(nil)
        close()
    }

    override func resignKey() {
        super.resignKey()
        resignedKeyAt = Date()
        // A menu (the project dropdown) takes key status briefly; only a real switch closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !isPinned, isVisible, !isKeyWindow, NSApp.keyWindow == nil || NSApp.keyWindow?.isKind(of: NSPanel.self) == false else { return }
            close()
        }
    }

    // MARK: Pinning

    var isPinned: Bool { chrome.pinned }

    /// Pinned, the panel stops closing on its own: no click-outside monitor, no
    /// close on losing key status, and it stays put when the app switches — and on its
    /// own Space. Unpinned it is gone the moment it loses the keyboard, so it can follow
    /// the user to every Space; pinned and still on all of them, it floated over every
    /// other desktop's windows.
    private func pinnedDidChange() {
        if chrome.pinned {
            removeMonitors()
            collectionBehavior.remove([.transient, .canJoinAllSpaces])
        } else {
            collectionBehavior.insert([.transient, .canJoinAllSpaces])
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

