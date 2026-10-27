import AppKit
import SwiftUI

/// The Transform window: one at a time, floating beside the files, sized to what it
/// shows. Files dropped on the Transform place open it.
@MainActor
final class TransformWindow {
    static let shared = TransformWindow()

    private var panel: TransformPanel?
    private var model: TransformModel?

    /// Opens Transform on `urls` near `point` (screen coordinates). What's made goes
    /// through `produce` when it's for the shelf.
    func open(_ urls: [URL], near point: CGPoint?,
              produce: @escaping (_ done: String, _ from: [URL], _ each: Bool, _ work: @escaping @Sendable ([URL], URL) -> [URL]) -> Void) {
        close()
        let model = TransformModel(files: urls)
        self.model = model
        let view = TransformView(model: model, run: { [weak self, weak model] in
            model?.run(produce: produce) { self?.close() }
        }, close: { [weak self] in self?.close() })
        // Room around the pane for its shadow.
        let host = NSHostingController(rootView: view.padding(24))
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        let panel = TransformPanel(contentViewController: host)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        let size = host.view.fittingSize
        panel.setFrame(Self.frame(size: size, near: point), display: false)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    func debugSelect(_ action: TransformModel.Action) { model?.settings.action = action }
    #endif

    func close() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    /// Beside `point`, top-aligned to it, kept on its screen; centred when there's none.
    private static func frame(size: CGSize, near point: CGPoint?) -> CGRect {
        let screen = point.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = point.map { CGPoint(x: $0.x + 20, y: $0.y - size.height + 60) }
            ?? CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}

/// A borderless panel that takes the keyboard (its fields, Return and Escape).
private final class TransformPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
