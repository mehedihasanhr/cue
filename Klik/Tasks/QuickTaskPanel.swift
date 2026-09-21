import AppKit
import SwiftUI

/// The task form as a floating window at the pointer (⌥/), for jotting a task
/// down from anywhere without going to the island. Frosted dark glass with a grain
/// so text stays legible over anything; the island's cards (captures, clipboard
/// entries, assets, colors) can be dragged into its description or pasted there.
/// Moves by the strip along its top, so a drag in the text selects. Closes on ⎋,
/// on Create / Cancel, on a click outside, or when it loses key status.
final class QuickTaskPanel: NSPanel {
    static let defaultSize = CGSize(width: IslandGeometry.formWidth, height: IslandGeometry.formContentHeight + 8)
    /// Room around the glass for its shadow.
    private static let margin: CGFloat = 24
    private var monitors: [Any] = []
    private let finish: (PromptAnswer?) -> Void
    /// The glass's size; a form that fits itself to its content changes it.
    private let sizing = Sizing()

    @Observable
    final class Sizing {
        var size = QuickTaskPanel.defaultSize
    }

    /// The glass at `size`, keeping its top-left corner where it is.
    private struct Sized<Content: View>: View {
        let sizing: Sizing
        let content: Content

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            content
                .padding(.top, 8)
                .frame(width: sizing.size.width, height: sizing.size.height)
                .liquidGlass(cornerRadius: 22)
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

        let root = Sized(sizing: sizing, content: form { [weak self] in self?.close() })
        let host = NSHostingView(rootView: root)
        let full = CGRect(origin: .zero, size: CGSize(width: Self.defaultSize.width + Self.margin * 2, height: Self.defaultSize.height + Self.margin * 2))
        host.frame = full
        host.autoresizingMask = [.width, .height]
        // Anything dropped on the panel — not just on the editor — goes into the description.
        let container = DropCatcher(frame: full)
        container.editor = { [weak self] in self?.editor as? RichTextView }
        container.addSubview(host)
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

    override var canBecomeKey: Bool { true }

    /// Resizes the glass to `size` (the window grows around it), keeping the top-left
    /// corner in place and staying on screen.
    func resize(to size: CGSize) {
        guard size != sizing.size else { return }
        sizing.size = size
        var frame = frame
        let full = CGSize(width: size.width + Self.margin * 2, height: size.height + Self.margin * 2)
        frame.origin.y = frame.maxY - full.height
        frame.size = full
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX - Self.margin + 8), visible.maxX - full.width + Self.margin - 8)
            frame.origin.y = min(max(frame.minY, visible.minY - Self.margin + 8), visible.maxY - full.height + Self.margin - 8)
        }
        setFrame(frame, display: true, animate: true)
    }

    /// The largest glass allowed: 60 % of the screen either way.
    static func maxSize(on screen: NSScreen?) -> CGSize {
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(width: (visible.width * 0.6).rounded(), height: (visible.height * 0.6).rounded())
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
            guard let self, isVisible, !isKeyWindow, NSApp.keyWindow == nil || NSApp.keyWindow?.isKind(of: NSPanel.self) == false else { return }
            close()
        }
    }

    private func installMonitors() {
        removeMonitors()
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

