import AppKit
import SwiftUI

/// The task form as a floating window at the pointer (⌥/), for jotting a task
/// down from anywhere without going to the island. Frosted dark glass with a grain
/// so text stays legible over anything; the island's cards (captures, clipboard
/// entries, assets, colors) can be dragged into its description or pasted there.
/// Closes on ⎋, on Create / Cancel, on a click outside, or when it loses key status.
final class QuickTaskPanel: NSPanel {
    private static let size = CGSize(width: IslandGeometry.formWidth, height: IslandGeometry.formContentHeight + 8)
    /// Room around the glass for its shadow.
    private static let margin: CGFloat = 24
    private var monitors: [Any] = []
    private let finish: (PromptAnswer?) -> Void

    init(store: TaskStore, finish: @escaping (PromptAnswer?) -> Void) {
        self.finish = finish
        super.init(
            contentRect: CGRect(origin: .zero, size: CGSize(width: Self.size.width + Self.margin * 2, height: Self.size.height + Self.margin * 2)),
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
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow

        let prompt = IslandPrompt(kind: .task(project: nil))
        let root = TaskFormRow(prompt: prompt, store: store) { [weak self] answer in
            self?.finish(answer)
            self?.close()
        }
        .padding(.top, 8)
        .frame(width: Self.size.width, height: Self.size.height)
        .liquidGlass(cornerRadius: 22)
        .padding(Self.margin)
        let host = NSHostingView(rootView: root)
        let full = CGRect(origin: .zero, size: CGSize(width: Self.size.width + Self.margin * 2, height: Self.size.height + Self.margin * 2))
        host.frame = full
        host.autoresizingMask = [.width, .height]
        // Anything dropped on the panel — not just on the editor — goes into the description.
        let container = DropCatcher(frame: full)
        container.editor = { [weak self] in self?.editor as? MarkdownEditor.EditorTextView }
        container.addSubview(host)
        contentView = container
    }

    /// The panel's content view: forwards files and images dropped anywhere on the
    /// glass to the description editor.
    private final class DropCatcher: NSView {
        var editor: () -> MarkdownEditor.EditorTextView? = { nil }

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

    /// The description editor, for pasting island cards into it.
    var editor: NSTextView? {
        func find(in view: NSView) -> NSTextView? {
            if let editor = view as? MarkdownEditor.EditorTextView { return editor }
            for subview in view.subviews { if let found = find(in: subview) { return found } }
            return nil
        }
        return contentView.flatMap(find)
    }

    /// Shows the form with its top-left corner just under the pointer, kept on screen.
    func show(at point: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = frame.size
        var origin = CGPoint(x: point.x - Self.margin - 24, y: point.y - size.height + Self.margin + 12)
        origin.x = min(max(origin.x, visible.minX + 8 - Self.margin), visible.maxX - size.width - 8 + Self.margin)
        origin.y = min(max(origin.y, visible.minY + 8 - Self.margin), visible.maxY - size.height - 8 + Self.margin)
        setFrameOrigin(origin)
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

