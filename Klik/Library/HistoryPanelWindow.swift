import AppKit
import SwiftUI

/// The captures panel as a floating window that pops up at the mouse pointer
/// (⌥V by default) — the same content as the menu-bar popover, without the anchor.
/// Closes on ⎋, on any click outside it, or when another window takes focus.
final class HistoryPanelWindow: NSPanel {
    private var monitors: [Any] = []

    init(rootView: some View) {
        super.init(
            contentRect: CGRect(origin: .zero, size: HistoryView.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow

        let host = NSHostingView(rootView: rootView
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.12)))
        )
        host.frame = CGRect(origin: .zero, size: HistoryView.size)
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    /// Shows the panel with its top-left corner just under the pointer, kept on screen.
    func show(at point: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = frame.size
        var origin = CGPoint(x: point.x - 24, y: point.y - size.height + 12)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
        installMonitors()
    }

    override func close() {
        removeMonitors()
        super.close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self, isVisible else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { close(); return nil }
                return event
            }
            if event.window !== self { close() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}
